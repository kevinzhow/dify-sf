// dify-spec: web/app/components/workflow/block-selector/__tests__/start-blocks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/start_panel.dart';

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('StartBlocks', () {
    group('Filtering and Selection', () {
      testWidgets('should render available start blocks and forward selection', (t) async {
        final semantics = t.ensureSemantics();
        final rec = SelectRecorder();
        const types = ['start', 'trigger-webhook'];
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            child: StartBlocks(searchText: '', onSelect: rec.call, availableBlocksTypes: types),
          ),
        );
        final userInput = t.getSemantics(find.bySemanticsLabel('workflow.blocks.start')).getSemanticsData();
        expect(userInput.hint, 'workflow.nodes.start.userInputTipDescription');
        expect(find.text('workflow.blocks.trigger-webhook'), findsOneWidget);
        expect(find.text('workflow.blocks.originalStartNode'), findsOneWidget);
        expect(filterStartBlocks(searchText: '', availableBlocksTypes: types, hasStartNode: false), isNotEmpty);

        await tapText(t, 'workflow.blocks.start');
        expect(rec.calls, [('start', null)]);
        semantics.dispose();
      });

      testWidgets('should hide user input when a start node already exists or hideUserInput is enabled', (t) async {
        await pumpSelector(
          t,
          StartBlocks(
            searchText: '',
            onSelect: (_, [_]) {},
            availableBlocksTypes: const ['start'],
            hideUserInput: true,
          ),
          data: const BlockSelectorData(nodes: [(id: 'start', type: 'start')]),
        );
        expect(find.byType(SelectorRow), findsNothing);
        expect(find.text('workflow.blocks.start'), findsNothing);
        expect(
          filterStartBlocks(
            searchText: '',
            availableBlocksTypes: const ['start'],
            hasStartNode: true,
            hideUserInput: true,
          ),
          isEmpty,
        );
      });

      testWidgets('should show most common badge for user input in the start selector content', (t) async {
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            child: StartBlocks(
              searchText: '',
              onSelect: (_, [_]) {},
              availableBlocksTypes: const ['start'],
              showMostCommonBadge: true,
            ),
          ),
        );
        expect(find.text('WORKFLOW.BLOCKS.MOSTCOMMON'), findsOneWidget);
        expect(find.text('workflow.blocks.originalStartNode'), findsNothing);
      });

      testWidgets('should render built-in start block preview titles and Dify Team author', (t) async {
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            child: StartBlocks(
              searchText: '',
              onSelect: (_, [_]) {},
              availableBlocksTypes: const ['start', 'trigger-webhook'],
            ),
          ),
        );
        final mouse = await hover(t, find.text('workflow.blocks.trigger-webhook'));
        expect(find.text('workflow.customWebhook'), findsNothing);
        expect(find.text('workflow.blocks.trigger-webhook'), findsNWidgets(2));

        await mouse.moveTo(t.getCenter(find.text('workflow.blocks.start').first));
        await settle(t, 500);
        expect(find.text('tools.author workflow.difyTeam'), findsOneWidget);
      });

      testWidgets('should keep disabled user input reachable from the keyboard with the conflict reason', (t) async {
        final semantics = t.ensureSemantics();
        final rec = SelectRecorder();
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            child: StartBlocks(
              searchText: '',
              onSelect: rec.call,
              availableBlocksTypes: const ['start'],
              showMostCommonBadge: true,
              showUserInputDisabled: true,
            ),
          ),
        );
        const label = 'workflow.blocks.start. workflow.nodes.startPlaceholder.userInputConflictTip';
        final row = find.bySemanticsLabel(label);
        expect(row, findsOneWidget);
        expect(t.getSemantics(row).getSemanticsData().flagsCollection.isEnabled, isNot(Tristate.isTrue));

        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(hasFocusOn(t, find.text('workflow.blocks.start')), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pump();
        expect(rec.calls, isEmpty);
        semantics.dispose();
      });
    });
  });
}
