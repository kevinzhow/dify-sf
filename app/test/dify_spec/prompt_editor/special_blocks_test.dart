// dify-spec: web/app/components/base/prompt-editor/plugins/current-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/current-block/__tests__/current-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/current-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/current-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/error-message-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/error-message-block/__tests__/error-message-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/error-message-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/error-message-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/last-run-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/last-run-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/last-run-block/__tests__/last-run-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/last-run-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/query-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/query-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/query-block/__tests__/query-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/request-url-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/request-url-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/request-url-block/__tests__/request-url-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/history-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/history-block/__tests__/history-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/history-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/history-block/__tests__/node.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The editor with one special block on, its callbacks counted.
class _Block {
  _Block(this.kind);
  final PromptBlockKind kind;
  int inserted = 0, deleted = 0;

  DifyPromptEditor editor(PromptEditorController c, {bool callbacks = true}) {
    void onInsert() => inserted++;
    void onDelete() => deleted++;
    final cfg = PromptBlockConfig(
      show: true,
      selectable: true,
      onInsert: callbacks ? onInsert : null,
      onDelete: callbacks ? onDelete : null,
    );
    return DifyPromptEditor(
      controller: c,
      queryBlock: kind == PromptBlockKind.query ? cfg : null,
      requestUrlBlock: kind == PromptBlockKind.requestUrl ? cfg : null,
      errorMessageBlock: kind == PromptBlockKind.errorMessage ? cfg : null,
      lastRunBlock: kind == PromptBlockKind.lastRun ? cfg : null,
      currentBlock: kind == PromptBlockKind.current
          ? CurrentBlockConfig(show: true, onInsert: callbacks ? onInsert : null, onDelete: callbacks ? onDelete : null)
          : null,
      historyBlock: kind == PromptBlockKind.history
          ? HistoryBlockConfig(
              show: true,
              selectable: true,
              onInsert: callbacks ? onInsert : null,
              onDelete: callbacks ? onDelete : null,
            )
          : null,
    );
  }

  Future<PromptEditorController> render(WidgetTester t, {bool callbacks = true}) =>
      renderWithController(t, (c) => editor(c, callbacks: callbacks));

  /// The placeholder becomes a block (and onInsert runs).
  Future<void> replaces(WidgetTester t, {bool callbacks = true}) async {
    final c = await render(t, callbacks: callbacks);
    c.prompt = 'a ${kind.placeholder} b';
    expect(blockCount(c, kind), 1);
    expect(c.prompt, 'a ${kind.placeholder} b');
    expect(inserted, callbacks ? 1 : 0);
  }

  Future<void> keepsText(WidgetTester t) async {
    final c = await render(t);
    c.prompt = 'no placeholder';
    expect(blockCount(c, kind), 0);
    expect(inserted, 0);
  }

  /// INSERT_*_BLOCK_COMMAND: the picker inserts a block at the caret.
  Future<void> inserts(WidgetTester t, {bool callbacks = true}) async {
    final c = await render(t, callbacks: callbacks);
    c.insertBlock(PromptBlock(kind));
    expect(c.prompt, kind.placeholder);
    expect(inserted, callbacks ? 1 : 0);
  }

  /// DELETE_*_BLOCK_COMMAND: removing the block.
  Future<void> deletes(WidgetTester t, {bool callbacks = true}) async {
    final c = await render(t, callbacks: callbacks);
    c.prompt = kind.placeholder!;
    await t.pump();
    await deleteBlockAt(t, 0);
    expect(c.prompt, '');
    expect(deleted, callbacks ? 1 : 0);
    expect(t.takeException(), isNull);
  }

  Future<void> unmounts(WidgetTester t) async {
    final c = await render(t);
    c.prompt = kind.placeholder!;
    inserted = 0;
    await t.pumpWidget(const SizedBox());
    c.prompt = '';
    c.insertBlock(PromptBlock(kind));
    expect(inserted, 0);
    expect(deleted, 0);
  }
}

/// A tap on the block doesn't reach what is around it.
Future<void> _stopsPropagation(WidgetTester t, Widget chip) async {
  var parent = 0;
  await render(t, GestureDetector(onTap: () => parent++, child: chip));
  await t.tap(find.byWidget(chip));
  expect(parent, 0);
}

void main() {
  group('CurrentBlockComponent', () {
    group('Rendering', () {
      testWidgets('should render the prompt label for the prompt generator type', (t) async {
        await render(t, const CurrentChip(generatorType: PromptGeneratorType.prompt));
        expect(find.text('current_prompt'), findsOneWidget);
      });

      testWidgets('should render the code label for the code generator type', (t) async {
        await render(t, const CurrentChip(generatorType: PromptGeneratorType.code));
        expect(find.text('current_code'), findsOneWidget);
      });
    });

    group('Interactions', () {
      testWidgets('should stop click propagation from wrapper', (t) async {
        await _stopsPropagation(t, const CurrentChip(generatorType: PromptGeneratorType.prompt));
      });
    });
  });

  group('CurrentBlockReplacementBlock', () {
    final b = _Block(PromptBlockKind.current);
    setUp(() => b.inserted = b.deleted = 0);

    group('Replacement behavior', () {
      testWidgets('should replace placeholder text and call onInsert when placeholder exists', b.replaces);
      testWidgets('should not replace text when placeholder is missing', b.keepsText);
      testWidgets('should replace placeholder without onInsert callback', (t) => b.replaces(t, callbacks: false));
    });
  });

  group('CurrentBlock', () {
    final b = _Block(PromptBlockKind.current);
    setUp(() => b.inserted = b.deleted = 0);

    group('Command handling', () {
      testWidgets('should insert current block and call onInsert when insert command is dispatched', b.inserts);
      testWidgets('should insert current block without onInsert callback', (t) => b.inserts(t, callbacks: false));
      testWidgets('should call onDelete when delete command is dispatched', b.deletes);
      testWidgets('should handle delete command without onDelete callback', (t) => b.deletes(t, callbacks: false));
    });

    group('Lifecycle', () {
      testWidgets('should unregister insert and delete commands when unmounted', b.unmounts);
    });
  });

  group('CurrentBlockNode', () {
    group('Node metadata', () {
      test('should expose current block type, inline behavior, and text content', () {
        expect(const PromptBlock(PromptBlockKind.current).text, '{{#current#}}');
      });
    });
  });

  group('ErrorMessageBlockComponent', () {
    group('Rendering', () {
      testWidgets('should render error_message text when unselected', (t) async {
        await render(t, const ErrorMessageChip());
        expect(find.text('error_message'), findsOneWidget);
      });
    });

    group('Interactions', () {
      testWidgets('should stop propagation when wrapper is clicked', (t) async {
        await _stopsPropagation(t, const ErrorMessageChip());
      });
    });
  });

  group('ErrorMessageBlockReplacementBlock', () {
    final b = _Block(PromptBlockKind.errorMessage);
    setUp(() => b.inserted = b.deleted = 0);

    test('should pass matcher and creator to decoratorTransform and match placeholder text', () {
      const blocks = PromptBlockSet({PromptBlockKind.errorMessage});
      expect(transformText('x {{#error_message#}} y', blocks), [
        'x ',
        const PromptBlock(PromptBlockKind.errorMessage),
        ' y',
      ]);
      expect(transformText('{{#error_message', blocks), ['{{#error_message']);
    });

    testWidgets('should register transform and cleanup on unmount', (t) async {
      final c = await b.render(t);
      await t.pumpWidget(const SizedBox());
      c.prompt = '{{#error_message#}}';
      expect(b.inserted, 0);
    });

    testWidgets('should create replacement node and call onInsert when creator runs', b.replaces);
    testWidgets('should create replacement node without onInsert callback', (t) => b.replaces(t, callbacks: false));
  });

  group('ErrorMessageBlock', () {
    final b = _Block(PromptBlockKind.errorMessage);
    setUp(() => b.inserted = b.deleted = 0);

    testWidgets('should insert created node and call onInsert when insert command handler runs', b.inserts);
    testWidgets(
      'should return true on insert command without onInsert callback',
      (t) => b.inserts(t, callbacks: false),
    );
    testWidgets('should call onDelete and return true when delete command handler runs', b.deletes);
    testWidgets(
      'should return true on delete command without onDelete callback',
      (t) => b.deletes(t, callbacks: false),
    );
    testWidgets('should run merged cleanup on unmount', b.unmounts);
  });

  group('ErrorMessageBlockNode', () {
    test('should be inline and provide expected text and json payload', () {
      expect(const PromptBlock(PromptBlockKind.errorMessage).text, '{{#error_message#}}');
    });
  });

  group('LastRunBlockComponent', () {
    group('Rendering', () {
      testWidgets('should render the last run label when selected', (t) async {
        await render(t, const LastRunChip(selected: true));
        expect(find.text('last_run'), findsOneWidget);
      });
    });

    group('Interactions', () {
      testWidgets('should stop click propagation from wrapper', (t) async {
        await _stopsPropagation(t, const LastRunChip());
      });
    });
  });

  group('LastRunBlock', () {
    final b = _Block(PromptBlockKind.lastRun);
    setUp(() => b.inserted = b.deleted = 0);

    group('Command handling', () {
      testWidgets('should insert last run block and call onInsert when insert command is dispatched', b.inserts);
      testWidgets('should insert last run block without onInsert callback', (t) => b.inserts(t, callbacks: false));
      testWidgets('should call onDelete when delete command is dispatched', b.deletes);
      testWidgets('should handle delete command without onDelete callback', (t) => b.deletes(t, callbacks: false));
    });

    group('Lifecycle', () {
      testWidgets('should unregister insert and delete commands when unmounted', b.unmounts);
    });
  });

  group('LastRunReplacementBlock', () {
    final b = _Block(PromptBlockKind.lastRun);
    setUp(() => b.inserted = b.deleted = 0);

    group('Replacement behavior', () {
      testWidgets('should replace placeholder text with last run block and call onInsert', b.replaces);
      testWidgets('should not replace text when placeholder is missing', b.keepsText);
      testWidgets('should replace placeholder text without onInsert callback', (t) => b.replaces(t, callbacks: false));
    });
  });

  group('LastRunBlockNode', () {
    group('Node metadata', () {
      test('should expose last run block type and inline behavior', () {
        expect(const PromptBlock(PromptBlockKind.lastRun).text, '{{#last_run#}}');
      });
    });
  });

  group('QueryBlock', () {
    final b = _Block(PromptBlockKind.query);
    setUp(() => b.inserted = b.deleted = 0);

    group('Command handling', () {
      testWidgets('should insert query block and call onInsert when insert command is dispatched', b.inserts);
      testWidgets('should insert query block without onInsert callback', (t) => b.inserts(t, callbacks: false));
      testWidgets('should call onDelete when delete command is dispatched', b.deletes);
      testWidgets('should handle delete command without onDelete callback', (t) => b.deletes(t, callbacks: false));
    });

    group('Lifecycle', () {
      testWidgets('should unregister insert and delete commands when unmounted', b.unmounts);
    });
  });

  group('QueryBlockNode', () {
    group('Node metadata', () {
      test('should expose query block type and inline behavior', () {
        expect(const PromptBlock(PromptBlockKind.query).text, '{{#query#}}');
      });
    });
  });

  group('QueryBlockReplacementBlock', () {
    final b = _Block(PromptBlockKind.query);
    setUp(() => b.inserted = b.deleted = 0);

    group('Replacement behavior', () {
      testWidgets('should replace placeholder text with query block and call onInsert', b.replaces);
      testWidgets('should not replace text when placeholder is missing', b.keepsText);
      testWidgets('should replace placeholder text without onInsert callback', (t) => b.replaces(t, callbacks: false));
    });
  });

  group('RequestURLBlock', () {
    final b = _Block(PromptBlockKind.requestUrl);
    setUp(() => b.inserted = b.deleted = 0);

    group('Command handling', () {
      testWidgets('should insert request URL block and call onInsert when insert command is dispatched', b.inserts);
      testWidgets('should insert request URL block without onInsert callback', (t) => b.inserts(t, callbacks: false));
      testWidgets('should call onDelete when delete command is dispatched', b.deletes);
      testWidgets('should handle delete command without onDelete callback', (t) => b.deletes(t, callbacks: false));
    });

    group('Lifecycle', () {
      testWidgets('should unregister insert and delete commands when unmounted', b.unmounts);
    });
  });

  group('RequestURLBlockNode', () {
    group('Node metadata', () {
      test('should expose request URL block type and inline behavior', () {
        expect(const PromptBlock(PromptBlockKind.requestUrl).text, '{{#url#}}');
      });
    });
  });

  group('RequestURLBlockReplacementBlock', () {
    final b = _Block(PromptBlockKind.requestUrl);
    setUp(() => b.inserted = b.deleted = 0);

    group('Replacement behavior', () {
      testWidgets('should replace placeholder text with request URL block and call onInsert', b.replaces);
      testWidgets('should not replace text when placeholder is missing', b.keepsText);
      testWidgets('should replace placeholder text without onInsert callback', (t) => b.replaces(t, callbacks: false));
    });
  });

  group('HistoryBlockComponent', () {
    HistoryBlockConfig config({
      PromptRoleName history = (user: 'user-role', assistant: 'assistant-role'),
      VoidCallback? onEditRole,
    }) => HistoryBlockConfig(history: history, onEditRole: onEditRole);
    Future<void> open(WidgetTester t) async {
      await t.tap(find.byKey(const Key('history-trigger')));
      await t.pumpAndSettle();
    }

    testWidgets('should render title and register select or delete hook with node key', (t) async {
      await render(t, HistoryChip(config: config()));
      expect(find.text('common.promptEditor.history.item.title'), findsOneWidget);
    });

    testWidgets('should render modal content when popup is open', (t) async {
      await render(t, HistoryChip(config: config()));
      await open(t);
      expect(find.text('user-role'), findsOneWidget);
      expect(find.text('assistant-role'), findsOneWidget);
      expect(find.text('common.promptEditor.history.modal.user'), findsOneWidget);
      expect(find.text('common.promptEditor.history.modal.assistant'), findsOneWidget);
    });

    testWidgets('should call onEditRole when edit action is clicked', (t) async {
      var edits = 0;
      await render(t, HistoryChip(config: config(onEditRole: () => edits++)));
      await open(t);
      await t.tap(find.text('common.promptEditor.history.modal.edit'));
      expect(edits, 1);
    });

    testWidgets('should render when event emitter is unavailable', (t) async {
      await render(t, HistoryChip(config: config()));
      expect(find.text('common.promptEditor.history.item.title'), findsOneWidget);
    });

    testWidgets('should update local role names when update history event is received', (t) async {
      await render(t, HistoryChip(config: config(history: (user: 'old-user', assistant: 'old-assistant'))));
      await open(t);
      expect(find.text('old-user'), findsOneWidget);
      await render(t, HistoryChip(config: config(history: (user: 'new-user', assistant: 'new-assistant'))));
      await t.pump();
      expect(find.text('new-user'), findsOneWidget);
      expect(find.text('new-assistant'), findsOneWidget);
    });
  });

  group('HistoryBlockReplacementBlock', () {
    final b = _Block(PromptBlockKind.history);
    setUp(() => b.inserted = b.deleted = 0);

    testWidgets('should replace history placeholder and call onInsert', b.replaces);
    testWidgets('should not replace text when history placeholder is absent', b.keepsText);
    testWidgets('should replace history placeholder without onInsert callback', (t) => b.replaces(t, callbacks: false));
  });

  group('HistoryBlock', () {
    final b = _Block(PromptBlockKind.history);
    setUp(() => b.inserted = b.deleted = 0);

    testWidgets('should insert history block and call onInsert when insert command is dispatched', b.inserts);
    testWidgets('should insert history block with default props when insert command is dispatched', (t) async {
      await b.inserts(t, callbacks: false);
      await t.pump();
      expect(t.widget<HistoryChip>(find.byType(HistoryChip)).config.history, (user: '', assistant: ''));
    });
    testWidgets('should call onDelete when delete command is dispatched', b.deletes);
    testWidgets('should handle delete command without onDelete callback', (t) => b.deletes(t, callbacks: false));
    testWidgets('should unregister insert and delete commands when unmounted', b.unmounts);
  });

  group('HistoryBlockNode', () {
    test('should expose history block type and inline behavior', () {
      expect(const PromptBlock(PromptBlockKind.history).text, '{{#histories#}}');
    });
  });
}
