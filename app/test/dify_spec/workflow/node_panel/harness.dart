import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

export '../../dify_test_i18n.dart';
export '../context_menu/harness.dart';

/// The node panel's actions on [h] (deleting a referenced node is confirmed with [confirm]).
NodePanelActions panelActions(
  Harness h, {
  WorkflowMenuOptions options = const WorkflowMenuOptions(),
  bool confirm = true,
}) => NodePanelActions(
  controller: h.controller,
  canvas: h.canvas,
  store: h.store,
  options: options,
  confirmDelete: (_, _) async => confirm,
);

/// [child] in a Material app, with [h]'s store (and [preferences]) in scope, at the right edge of the screen.
Widget panelApp(Harness h, Widget child, {WorkflowPreferences? preferences, Widget? before}) => MaterialApp(
  home: Material(
    child: WorkflowStoreScope(
      store: h.store,
      preferences: preferences,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Align(alignment: Alignment.topLeft, child: before),
          ),
          child,
        ],
      ),
    ),
  ),
);

/// The control whose accessible name is [label] (Dify's `getByRole('button', { name })`).
Finder buttonNamed(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// The resize handle (Dify's `getByRole('separator')`) and whether it has the focus.
ResizeHandle separator(WidgetTester t) => t.widget<ResizeHandle>(find.byType(ResizeHandle));
bool separatorFocused(WidgetTester t) => t
    .widget<Focus>(find.descendant(of: find.byType(ResizeHandle), matching: find.byType(Focus)).first)
    .focusNode!
    .hasFocus;

/// The panel's width as laid out.
double panelWidth(WidgetTester t) => t.getSize(find.byType(AnimatedContainer).first).width;

Future<void> settle(WidgetTester t, [int ms = 400]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}
