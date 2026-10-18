// dify-spec: web/app/components/base/features/new-feature-panel/conversation-opener/__tests__/modal.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const defaultData = {
  'enabled': true,
  'opening_statement': 'Hello, how can I help?',
  'suggested_questions': ['Question 1', 'Question 2'],
};

final saved = <Json>[];
var cancelled = 0;
final autoAdded = <List<Json>>[];

Widget modal({
  Json data = defaultData,
  List<Json> promptVariables = const [],
  List<Json> workflowVariables = const [],
  bool withAutoAdd = false,
}) => OpeningSettingModal(
  data: data,
  onSave: saved.add,
  onCancel: () => cancelled++,
  promptVariables: promptVariables,
  workflowVariables: workflowVariables,
  onAutoAddPromptVariable: withAutoAdd ? autoAdded.add : null,
);

Future<void> renderModal(WidgetTester t, Widget w) async {
  await render(t, w, fill: true);
  await settle(t);
}

/// The prompt editor's text (`getPromptEditor()`).
String editorText(WidgetTester t) => t
    .widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.controller is PromptEditorController))
    .controller!
    .text;

Finder get closeButton => button('common.operation.close');
Finder get saveButton => byText(r'operation\.save');
Finder get confirm => find.byType(ConfirmAddVar);
Finder inConfirm(String pattern) => find.descendant(of: confirm, matching: byText(pattern));
Finder get questionPlaceholder => byPlaceholder(r'openingStatement\.openingQuestionPlaceholder');

/// The bordered row around a question's input.
BoxDecoration rowOf(WidgetTester t, Finder input) => t
    .widgetList<Container>(find.ancestor(of: input, matching: find.byType(Container)))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .firstWhere((d) => d.border != null);

Color? borderOf(WidgetTester t, Finder input) => (rowOf(t, input).border! as Border).top.color;

void main() {
  setUp(() {
    useDifyTestTranslator();
    saved.clear();
    cancelled = 0;
    autoAdded.clear();
  });

  group('OpeningSettingModal', () {
    testWidgets('should render the modal title', (t) async {
      await renderModal(t, modal());
      expect(byText(r'feature\.conversationOpener\.title'), findsOneWidget);
    });

    testWidgets('should render the opening statement in the editor', (t) async {
      await renderModal(t, modal());
      expect(editorText(t), 'Hello, how can I help?');
    });

    testWidgets('should render suggested questions', (t) async {
      await renderModal(t, modal());
      expect(byDisplayValue('Question 1'), findsOneWidget);
      expect(byDisplayValue('Question 2'), findsOneWidget);
    });

    testWidgets('should render cancel and save buttons', (t) async {
      await renderModal(t, modal());
      expect(byText(r'operation\.cancel'), findsOneWidget);
      expect(saveButton, findsOneWidget);
    });

    testWidgets('should call onCancel when cancel is clicked', (t) async {
      await renderModal(t, modal());
      await tap(t, byText(r'operation\.cancel'));
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when close icon is clicked', (t) async {
      await renderModal(t, modal());
      await tap(t, closeButton);
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when close icon receives Enter key', (t) async {
      await renderModal(t, modal());
      await focusOn(t, closeButton);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when close icon receives Space key', (t) async {
      await renderModal(t, modal());
      await focusOn(t, closeButton);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when Escape is pressed on the dialog close control', (t) async {
      await renderModal(t, modal());
      await focusOn(t, closeButton);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 1);
    });

    testWidgets('should call onSave with updated data when save is clicked', (t) async {
      await renderModal(t, modal());
      await tap(t, saveButton);
      expect(saved.single['opening_statement'], 'Hello, how can I help?');
      expect(saved.single['suggested_questions'], ['Question 1', 'Question 2']);
    });

    testWidgets('should disable save when opening statement is empty', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': ''}));
      expect(isDisabled(t, r'operation\.save'), isTrue);
    });

    testWidgets('should add a new suggested question', (t) async {
      await renderModal(t, modal());
      expect(byDisplayValue('Question 1'), findsOneWidget);
      expect(byDisplayValue('Question 2'), findsOneWidget);
      await tap(t, byText(r'variableConfig\.addOption'));
      expect(byDisplayValue('Question 1'), findsOneWidget);
      expect(byDisplayValue('Question 2'), findsOneWidget);
      expect(byDisplayValue(''), findsWidgets);
    });

    testWidgets('should focus a new suggested question without destructive styling', (t) async {
      await renderModal(t, modal());
      await tap(t, byText(r'variableConfig\.addOption'));
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '' && w.decoration?.hintText != null,
      );
      expect(t.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      expect(borderOf(t, input), isNot(DifyColors.componentsInputBorderDestructive));
      expect(borderOf(t, input), DifyColors.componentsInputBorderActive);
    });

    testWidgets('should delete a suggested question via save verification', (t) async {
      await renderModal(
        t,
        modal(
          data: {
            ...defaultData,
            'suggested_questions': ['Question 1'],
          },
        ),
      );
      expect(byDisplayValue('Question 1'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('delete-question-Question 1')));
      expect(byDisplayValue('Question 1'), findsNothing);
    });

    testWidgets('should update a suggested question value', (t) async {
      await renderModal(t, modal());
      await t.enterText(byDisplayValue('Question 1'), 'Updated Question');
      await t.pump();
      expect(byDisplayValue('Updated Question'), findsOneWidget);
    });

    testWidgets('should show confirm dialog when variables are not in prompt', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': 'Hello {{name}}'}));
      await tap(t, saveButton.first);
      expect(confirm, findsOneWidget);
    });

    testWidgets('should save without variable check when confirm cancel is clicked', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': 'Hello {{name}}'}));
      await tap(t, saveButton.first);
      await tap(t, inConfirm(r'operation\.cancel'));
      expect(saved, hasLength(1));
    });

    testWidgets('should show question count', (t) async {
      await renderModal(t, modal());
      expect(find.text('app-debug.openingStatement.openingQuestion'), findsOneWidget);
      expect(find.text('2/10'), findsOneWidget);
    });

    testWidgets('should render separate opener and question sections', (t) async {
      await renderModal(t, modal());
      expect(find.byKey(const ValueKey('opener-input-section')), findsOneWidget);
      expect(find.byKey(const ValueKey('opener-questions-section')), findsOneWidget);
      expect(byText(r'openingStatement\.editorTitle'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'openingStatement\.openingQuestionDescription')), findsOneWidget);
      expect(byText(r'openingStatement\.openingQuestionDescription'), findsNothing);
    });

    testWidgets('should show the opening questions description in an infotip', (t) async {
      await renderModal(t, modal());
      await hover(t, find.bySemanticsLabel(RegExp(r'openingStatement\.openingQuestionDescription')));
      await t.pump(const Duration(milliseconds: 350));
      await settle(t);
      expect(byText(r'openingStatement\.openingQuestionDescription'), findsOneWidget);
    });

    testWidgets('should call onAutoAddPromptVariable when confirm add is clicked', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': 'Hello {{name}}'}, withAutoAdd: true));
      await tap(t, saveButton.first);
      await tap(t, inConfirm(r'operation\.add'));
      expect(autoAdded.single.single['key'], 'name');
    });

    testWidgets('should not show add button when max questions reached', (t) async {
      await renderModal(
        t,
        modal(
          data: {
            'enabled': true,
            'opening_statement': 'Hello',
            'suggested_questions': [for (var i = 1; i <= 10; i++) 'Q$i'],
          },
        ),
      );
      expect(byText(r'variableConfig\.addOption'), findsNothing);
    });

    testWidgets('should apply and remove focused styling on question input focus/blur', (t) async {
      await renderModal(t, modal());
      final input = byDisplayValue('Question 1');
      expect(borderOf(t, input), isNot(DifyColors.componentsInputBorderActive));
      await tap(t, input);
      expect(borderOf(t, input), DifyColors.componentsInputBorderActive);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(borderOf(t, input), isNot(DifyColors.componentsInputBorderActive));
    });

    testWidgets('should apply and remove deleting styling on delete icon hover', (t) async {
      await renderModal(t, modal());
      final input = byDisplayValue('Question 1');
      expect(borderOf(t, input), isNot(DifyColors.componentsInputBorderDestructive));
      await hover(t, find.byKey(const ValueKey('delete-question-Question 1')));
      expect(borderOf(t, input), DifyColors.componentsInputBorderDestructive);
      await unhover(t);
      expect(borderOf(t, input), isNot(DifyColors.componentsInputBorderDestructive));
    });

    testWidgets('should handle save with empty suggested questions', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'suggested_questions': <String>[]}));
      await tap(t, saveButton);
      expect(saved.single['suggested_questions'], isEmpty);
    });

    testWidgets('should not save when opening statement is only whitespace', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': '   '}));
      await tap(t, saveButton);
      expect(saved, isEmpty);
    });

    testWidgets('should skip variable check when variables match prompt variables', (t) async {
      await renderModal(
        t,
        modal(
          data: {...defaultData, 'opening_statement': 'Hello {{name}}'},
          promptVariables: [
            {'key': 'name', 'name': 'Name', 'type': 'string', 'required': true},
          ],
        ),
      );
      await tap(t, saveButton);
      expect(confirm, findsNothing);
      expect(saved, hasLength(1));
    });

    testWidgets('should skip variable check when variables match workflow variables', (t) async {
      await renderModal(
        t,
        modal(
          data: {...defaultData, 'opening_statement': 'Hello {{name}}'},
          workflowVariables: [
            {'variable': 'name', 'label': 'Name', 'type': 'text-input', 'required': true},
          ],
        ),
      );
      await tap(t, saveButton);
      expect(confirm, findsNothing);
      expect(saved, hasLength(1));
    });

    testWidgets('should show confirm dialog when variables not in workflow variables', (t) async {
      await renderModal(
        t,
        modal(
          data: {...defaultData, 'opening_statement': 'Hello {{unknown}}'},
          workflowVariables: [
            {'variable': 'name', 'label': 'Name', 'type': 'text-input', 'required': true},
          ],
        ),
      );
      await tap(t, saveButton);
      expect(confirm, findsOneWidget);
    });

    testWidgets('should use updated opening statement after prop changes', (t) async {
      await renderModal(t, modal());
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': 'New greeting!'}));
      await tap(t, saveButton);
      expect(saved.single['opening_statement'], 'New greeting!');
    });

    testWidgets('should render empty opening statement with placeholder in editor', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': ''}));
      expect(editorText(t).trim(), isEmpty);
      final section = find.byKey(const ValueKey('opener-input-section'));
      expect(find.descendant(of: section, matching: byText(r'openingStatement\.placeholderLine1')), findsOneWidget);
      expect(find.descendant(of: section, matching: byText(r'openingStatement\.placeholderLine2')), findsOneWidget);
    });

    testWidgets('should render with empty suggested questions when field is missing', (t) async {
      await renderModal(t, modal(data: {'enabled': true, 'opening_statement': 'Hello, how can I help?'}));
      expect(byDisplayValue('Question 1'), findsNothing);
      expect(byDisplayValue('Question 2'), findsNothing);
    });

    testWidgets('should render prompt variable fallback key when name is empty', (t) async {
      await renderModal(
        t,
        modal(
          promptVariables: [
            {'key': 'account_id', 'name': '', 'type': 'string', 'required': true},
          ],
        ),
      );
      expect(find.byType(DifyPromptEditor), findsOneWidget);
      final block = t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor)).variableBlock!;
      expect(block.variables!.single.name, 'account_id');
    });

    testWidgets('should save reordered suggested questions after sortable setList', (t) async {
      await renderModal(t, modal());
      t.widget<ReorderableList>(find.byType(ReorderableList)).onReorderItem!(1, 0);
      await t.pump();
      await tap(t, saveButton);
      expect(saved.single['suggested_questions'], ['Question 2', 'Question 1']);
    });

    testWidgets('should not save when confirm dialog action runs with empty opening statement', (t) async {
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': 'Hello {{name}}'}));
      await tap(t, saveButton.first);
      expect(confirm, findsOneWidget);
      await renderModal(t, modal(data: {...defaultData, 'opening_statement': '   '}));
      await tap(t, inConfirm(r'operation\.cancel'));
      expect(saved, isEmpty);
    });

    testWidgets('cancels sorting with Escape without closing the dialog, then saves a confirmed reorder', (t) async {
      await renderModal(t, modal());
      final handle = find.bySemanticsLabel(RegExp(r'sort\.handle')).first;
      await tap(t, handle);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(cancelled, 0);
      expect(
        [
          for (final f in t.widgetList<TextField>(questionPlaceholder)) f.controller!.text,
        ],
        ['Question 1', 'Question 2'],
      );
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'question sort handle 0');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await tap(t, saveButton);
      expect(saved.single['suggested_questions'], ['Question 2', 'Question 1']);
    });
  });
}
