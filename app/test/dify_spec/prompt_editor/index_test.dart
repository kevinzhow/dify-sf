// dify-spec: web/app/components/base/prompt-editor/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('PromptEditor', () {
    group('Rendering', () {
      testWidgets('should render placeholder and call onChange with joined lexical text', (t) async {
        final changes = <String>[];
        await render(
          t,
          DifyPromptEditor(compact: true, placeholder: 'Type prompt', value: '', onChange: changes.add),
        );
        expect(find.text('Type prompt'), findsOneWidget);
        final field = t.widget<TextField>(find.byType(TextField));
        expect(field.style?.fontSize, 13);
        expect(field.style!.fontSize! * field.style!.height!, 20);
        await focusAt(t);
        await typeText(t, 'first line\nsecond line');
        expect(changes.last, 'first line\nsecond line');
        expect(find.text('Type prompt'), findsNothing);
      });
    });

    group('Event Emission', () {
      testWidgets('should emit dataset and history updates when corresponding props change', (t) async {
        Widget editor(List<PromptDataset> datasets, PromptRoleName history) => DifyPromptEditor(
          value: '{{#context#}} {{#histories#}}',
          contextBlock: ContextBlockConfig(show: true, datasets: datasets),
          historyBlock: HistoryBlockConfig(show: true, history: history),
        );
        await render(
          t,
          editor(const [PromptDataset(id: 'ds-1', name: 'Dataset One')], (user: 'user-role', assistant: 'a')),
        );
        expect(find.text('1'), findsOneWidget);
        expect(t.widget<HistoryChip>(find.byType(HistoryChip)).config.history.user, 'user-role');
        await render(
          t,
          editor(
            const [
              PromptDataset(id: 'ds-1', name: 'Dataset One'),
              PromptDataset(id: 'ds-2', name: 'Dataset Two'),
            ],
            (user: 'user-next', assistant: 'a'),
          ),
        );
        expect(find.text('2'), findsOneWidget);
        expect(t.widget<HistoryChip>(find.byType(HistoryChip)).config.history.user, 'user-next');
      });
    });

    group('Focus/Blur Callbacks', () {
      testWidgets('should call onFocus and onBlur when lexical focus/blur commands fire', (t) async {
        var focus = 0, blur = 0;
        await render(t, DifyPromptEditor(onFocus: () => focus++, onBlur: () => blur++));
        await focusAt(t);
        editorState(t).focusNode.unfocus();
        await t.pump();
        expect(focus, 1);
        expect(blur, 1);
      });
    });

    group('Props Typing', () {
      testWidgets('should render without onChange and not crash', (t) async {
        await render(t, const DifyPromptEditor(placeholder: 'Empty'));
        await focusAt(t);
        await typeText(t, 'x');
        expect(t.takeException(), isNull);
      });

      testWidgets('should render with editable=false', (t) async {
        await render(t, const DifyPromptEditor(editable: false, placeholder: 'read only'));
        expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      });

      testWidgets('should sync editable changes to the lexical editor instance', (t) async {
        await render(t, const DifyPromptEditor());
        expect(t.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
        await render(t, const DifyPromptEditor(editable: false));
        expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      });

      testWidgets('should render with isSupportFileVar=true', (t) async {
        await render(t, const DifyPromptEditor(isSupportFileVar: true, value: 'a {{name}} b'));
        expect(editorState(t).controller.blocks.variableValue, isTrue);
      });

      testWidgets('should render all block types when show=true', (t) async {
        await render(
          t,
          const DifyPromptEditor(
            value: '{{#context#}}{{#query#}} {{#histories#}}{{#n.x#}}{{#current#}}{{#url#}}{{#error_message#}}{{#last_run#}}',
            contextBlock: ContextBlockConfig(show: true),
            queryBlock: PromptBlockConfig(show: true),
            historyBlock: HistoryBlockConfig(show: true, history: (user: 'u', assistant: 'a')),
            variableBlock: VariableBlockConfig(show: true),
            workflowVariableBlock: WorkflowVariableBlockConfig(show: true),
            currentBlock: CurrentBlockConfig(show: true),
            requestUrlBlock: PromptBlockConfig(show: true),
            errorMessageBlock: PromptBlockConfig(show: true),
            lastRunBlock: PromptBlockConfig(show: true),
          ),
        );
        for (final type in [
          ContextChip,
          QueryChip,
          HistoryChip,
          WorkflowVariableChip,
          CurrentChip,
          RequestUrlChip,
          ErrorMessageChip,
          LastRunChip,
        ]) {
          expect(find.byType(type), findsOneWidget, reason: '$type');
        }
      });

      testWidgets('should render externalToolBlock when variableBlock is not shown', (t) async {
        await render(
          t,
          const DifyPromptEditor(
            variableBlock: VariableBlockConfig(show: false),
            externalToolBlock: ExternalToolBlockConfig(show: true),
          ),
        );
        expect(editorState(t).controller.blocks.variableValue, isTrue);
      });

      testWidgets('should unmount component to cover onRef cleanup', (t) async {
        await render(t, const DifyPromptEditor());
        await t.pumpWidget(const SizedBox());
        expect(t.takeException(), isNull);
      });

      testWidgets('should rerender without ref-driven update loops', (t) async {
        await render(t, const DifyPromptEditor(value: 'first'));
        await render(t, const DifyPromptEditor(value: 'second'));
        expect(editorState(t).controller.prompt, 'second');
        expect(t.takeException(), isNull);
      });
    });
  });
}
