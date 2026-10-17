// dify-spec: web/app/components/base/prompt-editor/plugins/context-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/context-block/__tests__/context-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/context-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/context-block/__tests__/node.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _datasets = [
  PromptDataset(id: '1', name: 'Dataset A', type: 'text'),
  PromptDataset(id: '2', name: 'Dataset B', type: 'text'),
];

Future<void> _chip(WidgetTester t, ContextBlockConfig config, {bool open = false}) async {
  await render(t, ContextChip(config: config));
  if (open) {
    await t.tap(find.text('${config.datasets.length}'));
    await t.pumpAndSettle();
  }
}

/// The editor with the context block on (Dify's replacement and insert plugins) and its chip's config.
Future<PromptEditorController> _editor(WidgetTester t, ContextBlockConfig config) =>
    renderWithController(t, (c) => DifyPromptEditor(controller: c, contextBlock: config));

ContextBlockConfig _chipConfig(WidgetTester t) => t.widget<ContextChip>(find.byType(ContextChip)).config;

void main() {
  group('ContextBlockComponent', () {
    group('Rendering', () {
      testWidgets('should display the context title', (t) async {
        await _chip(t, const ContextBlockConfig());
        expect(find.text('common.promptEditor.context.item.title'), findsOneWidget);
      });

      testWidgets('should display the dataset count', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets));
        expect(find.text('2'), findsOneWidget);
      });

      testWidgets('should display zero count when no datasets provided', (t) async {
        await _chip(t, const ContextBlockConfig());
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should render the file icon', (t) async {
        await _chip(t, const ContextBlockConfig());
        expect(find.byKey(const Key('file-icon')), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should hide the portal trigger when canNotAddContext is true', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets, canNotAddContext: true));
        expect(find.text('2'), findsNothing);
      });
    });

    group('Dropdown Content', () {
      testWidgets('should show dataset list when dropdown is open', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets), open: true);
        expect(find.text('Dataset A'), findsOneWidget);
        expect(find.text('Dataset B'), findsOneWidget);
      });

      testWidgets('should show modal title with dataset count when open', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets), open: true);
        expect(find.text('common.promptEditor.context.modal.title:{"num":2}'), findsOneWidget);
      });

      testWidgets('should show the add context button when open', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets), open: true);
        expect(find.text('common.promptEditor.context.modal.add'), findsOneWidget);
      });

      testWidgets('should show the footer text when open', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets), open: true);
        expect(find.text('common.promptEditor.context.modal.footer'), findsOneWidget);
      });

      testWidgets('should render folder icon for each dataset', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets), open: true);
        expect(find.byKey(const Key('folder-icon')), findsNWidgets(2));
      });

      testWidgets('should not render dropdown content when canNotAddContext is true', (t) async {
        await _chip(t, const ContextBlockConfig(datasets: _datasets, canNotAddContext: true));
        expect(find.text('Dataset A'), findsNothing);
        expect(find.text('common.promptEditor.context.modal.add'), findsNothing);
      });
    });

    group('User Interactions', () {
      testWidgets('should call onAddContext when add button is clicked', (t) async {
        var added = 0;
        await _chip(t, ContextBlockConfig(datasets: _datasets, onAddContext: () => added++), open: true);
        await t.tap(find.bySemanticsLabel('common.promptEditor.context.modal.add'));
        expect(added, 1);
      });
    });

    group('Event Emitter Subscription', () {
      testWidgets('should update local datasets when UPDATE_DATASETS_EVENT_EMITTER event fires', (t) async {
        await _chip(t, const ContextBlockConfig());
        expect(find.text('0'), findsOneWidget);
        await _chip(
          t,
          const ContextBlockConfig(
            datasets: [PromptDataset(id: '3', name: 'New Dataset')],
          ),
          open: true,
        );
        expect(find.text('1'), findsOneWidget);
        expect(find.text('New Dataset'), findsOneWidget);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle empty datasets array', (t) async {
        await _chip(t, const ContextBlockConfig(), open: true);
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should default datasets to empty array when undefined', (t) async {
        await _chip(t, const ContextBlockConfig());
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should handle single dataset', (t) async {
        await _chip(
          t,
          const ContextBlockConfig(
            datasets: [PromptDataset(id: '1', name: 'Single')],
          ),
          open: true,
        );
        expect(find.text('1'), findsOneWidget);
        expect(find.text('Single'), findsOneWidget);
      });

      testWidgets('should handle dataset with long name by truncating', (t) async {
        final longName = 'A' * 200;
        await _chip(
          t,
          ContextBlockConfig(
            datasets: [PromptDataset(id: '1', name: longName)],
          ),
          open: true,
        );
        final text = t.widget<Text>(find.text(longName));
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
      });
    });
  });

  group('ContextBlockReplacementBlock', () {
    group('Text Replacement Transform', () {
      testWidgets('should replace context placeholder text with a ContextBlockNode', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#context#}}';
        expect(blockCount(c, PromptBlockKind.context), 1);
      });

      testWidgets('should not replace text that is not the placeholder', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = 'just some normal text';
        expect(blockCount(c, PromptBlockKind.context), 0);
      });

      testWidgets('should not replace partial placeholder text', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#contex';
        expect(blockCount(c, PromptBlockKind.context), 0);
      });

      testWidgets('should pass datasets to the created ContextBlockNode', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, datasets: _datasets));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(blockCount(c, PromptBlockKind.context), 1);
        expect(_chipConfig(t).datasets, _datasets);
      });

      testWidgets('should pass canNotAddContext to the created ContextBlockNode', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, canNotAddContext: true));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(_chipConfig(t).canNotAddContext, isTrue);
      });
    });

    group('onInsert callback', () {
      testWidgets('should call onInsert when a placeholder is replaced', (t) async {
        var inserted = 0;
        final c = await _editor(t, ContextBlockConfig(show: true, onInsert: () => inserted++));
        c.prompt = '{{#context#}}';
        expect(inserted, 1);
      });

      testWidgets('should not call onInsert when no placeholder is found', (t) async {
        var inserted = 0;
        final c = await _editor(t, ContextBlockConfig(show: true, onInsert: () => inserted++));
        c.prompt = 'no placeholder here';
        expect(inserted, 0);
      });
    });

    group('Props Defaults', () {
      testWidgets('should default datasets to empty array', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(_chipConfig(t).datasets, isEmpty);
      });

      testWidgets('should default canNotAddContext to false', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(_chipConfig(t).canNotAddContext, isFalse);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle undefined datasets prop', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should handle empty datasets array', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, datasets: []));
        c.prompt = '{{#context#}}';
        await t.pump();
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should handle empty string text', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '';
        expect(blockCount(c, PromptBlockKind.context), 0);
      });
    });
  });

  group('ContextBlock', () {
    group('INSERT_CONTEXT_BLOCK_COMMAND handler', () {
      testWidgets('should insert a context block node with default props', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        await t.pump();
        expect(c.prompt, '{{#context#}}');
        expect(_chipConfig(t).datasets, isEmpty);
      });

      testWidgets('should call onInsert when provided', (t) async {
        var inserted = 0;
        final c = await _editor(t, ContextBlockConfig(show: true, onInsert: () => inserted++));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        expect(inserted, 1);
      });

      testWidgets('should pass datasets to the created node', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, datasets: _datasets));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        await t.pump();
        expect(_chipConfig(t).datasets, _datasets);
      });

      testWidgets('should pass canNotAddContext to the created node', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, canNotAddContext: true));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        await t.pump();
        expect(_chipConfig(t).canNotAddContext, isTrue);
      });
    });

    group('DELETE_CONTEXT_BLOCK_COMMAND handler', () {
      testWidgets('should return true when dispatched', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = 'a{{#context#}}';
        await t.pump();
        await deleteBlockAt(t, 1);
        expect(c.prompt, 'a');
      });

      testWidgets('should call onDelete when provided', (t) async {
        var deleted = 0;
        final c = await _editor(t, ContextBlockConfig(show: true, onDelete: () => deleted++));
        c.prompt = '{{#context#}}';
        await t.pump();
        await deleteBlockAt(t, 0);
        expect(deleted, 1);
        expect(c.prompt, '');
      });

      testWidgets('should not throw when onDelete is not provided', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.prompt = '{{#context#}}';
        await t.pump();
        await deleteBlockAt(t, 0);
        expect(t.takeException(), isNull);
      });
    });

    group('Props Defaults', () {
      testWidgets('should default onAddContext to a noop function', (t) async {
        await _chip(t, const ContextBlockConfig(), open: true);
        await t.tap(find.bySemanticsLabel('common.promptEditor.context.modal.add'));
        expect(t.takeException(), isNull);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle undefined datasets prop', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        await t.pump();
        expect(_chipConfig(t).datasets, isEmpty);
      });

      testWidgets('should handle empty datasets array', (t) async {
        final c = await _editor(t, const ContextBlockConfig(show: true, datasets: []));
        c.insertBlock(const PromptBlock(PromptBlockKind.context));
        await t.pump();
        expect(_chipConfig(t).datasets, isEmpty);
      });
    });

    group('Lifecycle', () {
      testWidgets('should unregister commands on unmount', (t) async {
        var deleted = 0;
        final c = await _editor(t, ContextBlockConfig(show: true, onDelete: () => deleted++));
        c.prompt = '{{#context#}}';
        await t.pumpWidget(const SizedBox());
        c.prompt = '';
        expect(deleted, 0);
      });
    });
  });

  group('ContextBlockNode', () {
    group('getTextContent', () {
      test('should return the context placeholder', () {
        expect(const PromptBlock(PromptBlockKind.context).text, '{{#context#}}');
      });
    });
  });
}
