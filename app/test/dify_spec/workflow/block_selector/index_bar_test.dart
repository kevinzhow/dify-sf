// dify-spec: web/app/components/workflow/block-selector/__tests__/index-bar.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('IndexBar', () {
    group('Rendering', () {
      testWidgets('should let keyboard users scroll to the selected letter', (t) async {
        final a = GlobalKey();
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            height: 300,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: Column(
                      children: [
                        const SizedBox(height: 1000),
                        SizedBox(key: a, height: 40),
                      ],
                    ),
                  ),
                ),
                IndexBar(letters: const ['A'], itemKeys: {'A': a}),
              ],
            ),
          ),
        );
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(hasFocusOn(t, find.text('A')), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(t, 500);
        expect(scroll.offset, greaterThan(0));
      });
    });
  });
}
