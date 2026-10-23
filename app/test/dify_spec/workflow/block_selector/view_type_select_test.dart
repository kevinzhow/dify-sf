// dify-spec: web/app/components/workflow/block-selector/__tests__/view-type-select.spec.tsx
import 'dart:ui' show CheckedState;

import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

CheckedState _checked(WidgetTester t, String label) =>
    t.getSemantics(find.bySemanticsLabel(label)).getSemanticsData().flagsCollection.isChecked;

void main() {
  setUpBlockSelectorTests();

  group('ViewTypeSelect', () {
    testWidgets('exposes the current view as a required single choice', (t) async {
      final semantics = t.ensureSemantics();
      await pumpSelector(t, ViewTypeSelect(viewType: ViewType.flat, onChange: (_) {}));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.role == SemanticsRole.radioGroup &&
              w.properties.label == 'common.operation.view',
        ),
        findsOneWidget,
      );
      expect(_checked(t, 'workflow.tabs.listView'), CheckedState.isTrue);
      expect(_checked(t, 'workflow.tabs.treeView'), CheckedState.isFalse);
      semantics.dispose();
    });

    testWidgets('changes the view as arrow-key focus moves', (t) async {
      final semantics = t.ensureSemantics();
      var view = ViewType.flat;
      await pumpSelector(
        t,
        StatefulBuilder(
          builder: (context, setState) => ViewTypeSelect(viewType: view, onChange: (v) => setState(() => view = v)),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.bySemanticsLabel('workflow.tabs.listView')), isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(hasFocusOn(t, find.bySemanticsLabel('workflow.tabs.treeView')), isTrue);
      expect(_checked(t, 'workflow.tabs.listView'), CheckedState.isFalse);
      expect(_checked(t, 'workflow.tabs.treeView'), CheckedState.isTrue);
      semantics.dispose();
    });
  });
}
