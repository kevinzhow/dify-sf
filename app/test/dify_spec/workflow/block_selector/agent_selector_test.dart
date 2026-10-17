// dify-spec: web/app/components/workflow/block-selector/__tests__/agent-selector.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/blocks_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _start = 'agent-v-2.roster.nodeSelector.startFromScratch';
const _manage = 'agent-v-2.roster.nodeSelector.manageInAgentConsole';

Future<void> _render(WidgetTester t, {VoidCallback? onClose, VoidCallback? onStartFromScratch}) async {
  await pumpSelector(
    t,
    AgentSelectorContent(onSelect: (_) {}, onClose: onClose, onStartFromScratch: onStartFromScratch),
    data: BlockSelectorData(searchAgents: (_) async => const []),
  );
  await settle(t);
}

void main() {
  setUpBlockSelectorTests();

  group('AgentSelectorContent', () {
    testWidgets('offers the Agent Console link without a workspace preview gate', (t) async {
      await _render(t, onStartFromScratch: () {});
      expect(linkUrlOf(t, _manage), Uri.parse('/agents'));
      final list = find.byType(SingleChildScrollView);
      expect(find.descendant(of: list, matching: find.text(_manage)), findsNothing);
      // `h-7 rounded-md px-2 py-1.5 system-sm-regular text-text-secondary` for both footer actions.
      for (final label in [_start, _manage]) {
        final row = find.ancestor(of: find.text(label), matching: find.byType(SelectorRow)).first;
        expect(t.getSize(row).height, 28);
      }
    });

    testWidgets('should keep the listbox as the only scroll owner for agent options', (t) async {
      await _render(t);
      final list = find.byType(SingleChildScrollView);
      expect(list, findsOneWidget);
      expect(find.descendant(of: list, matching: find.byType(Scrollable)), findsOneWidget);
      final box = t.widget<ConstrainedBox>(find.ancestor(of: list, matching: find.byType(ConstrainedBox)).first);
      expect(box.constraints.maxHeight, 216);
    });

    testWidgets('should move focus from the combobox to actions outside the listbox', (t) async {
      await _render(t, onStartFromScratch: () {});
      expect(hasFocusOn(t, searchField('agent-v-2.roster.nodeSelector.searchPlaceholder')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text(_start)), isTrue);
      expect(find.descendant(of: find.byType(SingleChildScrollView), matching: find.text(_start)), findsNothing);
    });

    testWidgets('does not dismiss the combobox when pressing a footer action', (t) async {
      var closes = 0, starts = 0;
      await _render(t, onClose: () => closes++, onStartFromScratch: () => starts++);
      final g = await t.startGesture(t.getCenter(find.text(_start)), kind: PointerDeviceKind.mouse);
      await t.pump();
      expect(closes, 0);
      await g.up();
      await t.pump();
      expect(starts, 1);
      expect(closes, 0);
    });
  });
}
