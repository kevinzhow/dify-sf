// dify-spec: web/app/components/workflow/block-selector/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter/material.dart';

import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

typedef _Call = (String, Map<String, Object?>, Map<String, Object?>?);

/// A trigger showing whether the selector is open (Dify's `trigger={(props, state) => ...}`).
Widget _openStateTrigger(BuildContext context, DifyFloatingController c) =>
    DifyButton(onPressed: c.toggle, child: Text(c.isOpen ? 'selector-open' : 'selector-closed'));

const _searchBlock = 'workflow.tabs.searchBlock';
const _searchTrigger = 'workflow.tabs.searchTrigger';

void main() {
  setUpBlockSelectorTests();

  group('BlockSelector', () {
    testWidgets('resolves available blocks from the mounted workflow content owner', (t) async {
      await pumpSelector(
        t,
        BlockSelector(open: true, availableBlocksTypes: const ['code'], onSelect: (_, _, {toolDefaultValue}) {}),
        data: BlockSelectorData(blocks: [block('start', 'Start'), block('tool', 'Tool'), block('code', 'Code')]),
      );
      expect(find.text('Code'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Tool'), findsNothing);
    });

    testWidgets('opens with the real blocks tab, filters by search, selects a block, and clears search after close', (
      t,
    ) async {
      final calls = <_Call>[];
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM'), block('end', 'End')],
          availableBlocksTypes: const ['llm', 'end'],
          trigger: _openStateTrigger,
          onSelect: (type, defaults, {toolDefaultValue}) => calls.add((type, defaults, toolDefaultValue)),
        ),
      );
      await tapText(t, 'selector-closed');
      expect(dialogNamed('workflow.common.addBlock'), findsOneWidget);
      expect(searchField(_searchBlock), findsOneWidget);
      expect(rowText('LLM'), findsOneWidget);
      expect(rowText('End'), findsOneWidget);

      await t.enterText(find.descendant(of: searchField(_searchBlock), matching: find.byType(EditableText)), 'LLM');
      await t.pump();
      expect(rowText('LLM'), findsOneWidget);
      expect(rowText('End'), findsNothing);

      await t.tap(rowText('LLM'));
      await settle(t, 500);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'llm');
      expect(calls.single.$2, containsPair('type', 'llm'));
      expect(calls.single.$3, isNull);
      expect(searchField(_searchBlock), findsNothing);

      await tapText(t, 'selector-closed');
      expect(searchValue(t, _searchBlock), '');
      expect(rowText('End'), findsOneWidget);
    });

    testWidgets('resets to the default tab after closing', (t) async {
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm', 'start'],
          showStartTab: true,
          trigger: _openStateTrigger,
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'selector-closed');
      await tapText(t, 'workflow.tabs.start');
      expect(searchField(_searchTrigger), findsOneWidget);

      await tapText(t, 'selector-open');
      expect(searchField(_searchTrigger), findsNothing);

      await tapText(t, 'selector-closed');
      expect(searchField(_searchBlock), findsOneWidget);
    });

    testWidgets('preserves the current popup session until a controlled close actually unmounts it', (t) async {
      final changes = <bool>[];
      await pumpSelector(
        t,
        BlockSelector(
          open: true,
          onOpenChange: changes.add,
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm', 'start'],
          showStartTab: true,
          trigger: (context, c) => DifyButton(onPressed: c.toggle, child: const Text('selector-open')),
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'workflow.tabs.start');
      await t.enterText(
        find.descendant(of: searchField(_searchTrigger), matching: find.byType(EditableText)),
        'webhook',
      );
      await t.pump();
      await tapText(t, 'selector-open');

      expect(changes, contains(false));
      expect(tabSelected(t, 'workflow.tabs.start'), isTrue);
      expect(searchValue(t, _searchTrigger), 'webhook');
    });

    testWidgets('focuses search and exposes a non-tabbing close action for touch screen readers', (t) async {
      final semantics = t.ensureSemantics();
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm', 'start'],
          showStartTab: true,
          trigger: _openStateTrigger,
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'selector-closed');
      expect(hasFocusOn(t, searchField(_searchBlock)), isTrue);

      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(hasFocusOn(t, find.text('workflow.tabs.blocks')), isTrue);

      final close = find.bySemanticsLabel('common.operation.close');
      expect(close, findsOneWidget);
      expect(t.getSemantics(close).flagsCollection.isFocused, isNot(Tristate.isTrue));

      await tapText(t, 'workflow.tabs.start');
      expect(hasFocusOn(t, find.text('workflow.tabs.start')), isTrue);
      expect(hasFocusOn(t, searchField(_searchTrigger)), isFalse);
      semantics.dispose();
    });

    testWidgets('does not open or emit open changes when disabled', (t) async {
      final changes = <bool>[];
      await pumpSelector(
        t,
        BlockSelector(
          disabled: true,
          onOpenChange: changes.add,
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm'],
          trigger: _openStateTrigger,
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'selector-closed');
      expect(changes, isEmpty);
      expect(searchField(_searchBlock), findsNothing);
    });

    testWidgets('allows an open selector to close after it becomes disabled', (t) async {
      late StateSetter set;
      var open = true, disabled = false;
      await pumpSelector(
        t,
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return BlockSelector(
              open: open,
              disabled: disabled,
              onOpenChange: (v) => setState(() => open = v),
              blocks: [block('llm', 'LLM')],
              trigger: (context, c) => DifyButton(
                disabled: disabled,
                onPressed: c.toggle,
                child: const Text('selector-trigger'),
              ),
              onSelect: (_, _, {toolDefaultValue}) {},
            );
          },
        ),
      );
      expect(dialogNamed('workflow.common.addBlock'), findsOneWidget);

      set(() => disabled = true);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(dialogNamed('workflow.common.addBlock'), findsNothing);
    });

    testWidgets('returns focus to the trigger after Escape', (t) async {
      final trigger = FocusNode();
      addTearDown(trigger.dispose);
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          trigger: (context, c) =>
              DifyButton(focusNode: trigger, onPressed: c.toggle, child: const Text('selector-trigger')),
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'selector-trigger');
      expect(hasFocusOn(t, searchField(_searchBlock)), isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(trigger.hasFocus, isTrue);
      expect(dialogNamed('workflow.common.addBlock'), findsNothing);
    });

    testWidgets('preserves the custom trigger click handler', (t) async {
      var clicks = 0;
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm'],
          trigger: (context, c) => DifyButton(
            onPressed: () {
              clicks++;
              c.toggle();
            },
            child: const Text('open-selector'),
          ),
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'open-selector');
      expect(clicks, 1);
      expect(searchField(_searchBlock), findsOneWidget);
    });

    testWidgets('can render a prop-forwarding button component as the popover root', (t) async {
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm'],
          trigger: (context, c) => _ForwardingButtonTrigger(onPressed: c.toggle),
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'open-selector-root');
      expect(searchField(_searchBlock), findsOneWidget);
    });

    testWidgets('can render the shared Button trigger as the popover root', (t) async {
      await pumpSelector(
        t,
        BlockSelector(
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm'],
          trigger: (context, c) => DifyButton(
            variant: DifyButtonVariant.primary,
            onPressed: c.toggle,
            child: const Text('open-shared-button-trigger'),
          ),
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
      );
      await tapText(t, 'open-shared-button-trigger');
      expect(searchField(_searchBlock), findsOneWidget);
    });

    testWidgets('isolates popup keyboard events when opened from another keyboard-managed overlay', (t) async {
      final parentKeys = <LogicalKeyboardKey>[];
      await pumpSelector(
        t,
        Focus(
          onKeyEvent: (node, e) {
            parentKeys.add(e.logicalKey);
            return KeyEventResult.ignored;
          },
          child: BlockSelector(
            open: true,
            isolateKeyboardEvents: true,
            blocks: [block('llm', 'LLM'), block('end', 'End')],
            availableBlocksTypes: const ['llm', 'end'],
            onSelect: (_, _, {toolDefaultValue}) {},
          ),
        ),
      );
      final input = find.descendant(of: searchField(_searchBlock), matching: find.byType(EditableText));
      await t.enterText(input, 'LLM');
      await t.pump();
      for (final k in [LogicalKeyboardKey.keyL, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft]) {
        await t.sendKeyEvent(k);
      }
      await t.pump();
      expect(searchValue(t, _searchBlock), 'LLM');
      expect(parentKeys, isEmpty);
      expect(rowText('LLM'), findsOneWidget);
      expect(rowText('End'), findsNothing);
    });

    testWidgets('disables the start tab with a setup tooltip when an unconfigured start node is on the canvas', (
      t,
    ) async {
      await pumpSelector(
        t,
        BlockSelector(
          open: true,
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm', 'start'],
          showStartTab: true,
          defaultActiveTab: BlockSelectorTab.start,
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
        data: const BlockSelectorData(nodes: [(id: 'start-placeholder', type: 'start-placeholder')]),
      );
      await hover(t, find.text('workflow.tabs.start'));
      expect(find.text('workflow.tabs.unconfiguredStartDisabledTip'), findsOneWidget);
      expect(searchField(_searchBlock), findsOneWidget);
    });

    testWidgets('keeps the start tab enabled when a configured user input start node is on the canvas', (t) async {
      await pumpSelector(
        t,
        BlockSelector(
          open: true,
          blocks: [block('llm', 'LLM')],
          availableBlocksTypes: const ['llm', 'start', 'trigger-plugin'],
          showStartTab: true,
          defaultActiveTab: BlockSelectorTab.start,
          onSelect: (_, _, {toolDefaultValue}) {},
        ),
        data: const BlockSelectorData(nodes: [(id: 'start', type: 'start')]),
      );
      expect(tabDisabled(t, 'workflow.tabs.start'), isFalse);
      expect(find.text('workflow.nodes.startPlaceholder.userInputConflictTip'), findsOneWidget);
    });
  });
}

/// A button component forwarding its props to a plain button.
class _ForwardingButtonTrigger extends StatelessWidget {
  const _ForwardingButtonTrigger({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyButton(onPressed: onPressed, child: const Text('open-selector-root'));
}
