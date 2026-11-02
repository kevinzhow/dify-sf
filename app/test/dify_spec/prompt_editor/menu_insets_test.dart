// The variable/component picker of the prompt editor lays out in the root overlay, which reaches under the system
// bars (edge to edge): it must keep clear of the navigation bar, flipping above the caret line when needed.
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/component_picker.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('the picker stays above the system navigation bar', (t) async {
    useDifyTestTranslator();
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    t.view.padding = const FakeViewPadding(bottom: 120);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              // The editor ends 240 px above the window's bottom edge: the ~200 px menu fits below it without the
              // 120 px navigation bar, not with it.
              padding: EdgeInsets.only(bottom: 240),
              child: SizedBox(width: 600, child: DifyPromptEditor(workflowVariableBlock: testVarBlock)),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await focusAt(t);
    await typeText(t, '{');
    expect(menuOpen(), isTrue);
    final menu = t.getRect(find.byType(ComponentPickerMenu));
    expect(menu.bottom, lessThanOrEqualTo(600 - 120));
  });
}
