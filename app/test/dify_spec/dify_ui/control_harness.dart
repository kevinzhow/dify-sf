export 'harness.dart' show positioner;

export 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

export 'package:flutter/material.dart';
export 'package:flutter/semantics.dart';
export 'package:flutter/services.dart';
export 'package:flutter_test/flutter_test.dart';
export 'package:dify_sf_app/src/design/dify_tokens.g.dart';
export 'package:dify_sf_app/src/design/dify_icon.dart';
export 'package:dify_sf_app/src/design/widgets/widgets.dart';
export 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';

Future<void> renderControl(WidgetTester t, Widget w, {ThemeData? theme}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, child: w),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 250));
}

BoxDecoration inputDecoration(WidgetTester t) => t
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .firstWhere((d) => d.border != null);

Future<void> focusInput(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  await t.pump();
  expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
}

Future<void> openControlDialog(
  WidgetTester t, {
  bool dismissible = true,
  bool close = false,
  bool disabled = false,
  bool initialFocus = false,
}) async {
  await renderControl(
    t,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showDifyDialog<void>(
          context,
          dismissible: dismissible,
          builder: (ctx) => DifyDialogSurface(
            label: 'Dialog Title',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Dialog Title'),
                const Text('Dialog Description'),
                if (initialFocus) TextButton(autofocus: true, onPressed: () {}, child: const Text('Focus target')),
                if (close)
                  TextButton(onPressed: disabled ? null : () => Navigator.pop(ctx), child: const Text('Close dialog')),
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ],
            ),
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  );
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  await t.tap(find.text('Open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 250));
}
