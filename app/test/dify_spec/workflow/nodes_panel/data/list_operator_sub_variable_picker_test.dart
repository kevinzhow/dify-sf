// dify-spec: web/app/components/workflow/nodes/list-operator/components/__tests__/sub-variable-picker.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// [child] 360 wide at the top left, with Dify's test translator.
Future<void> pumpControl(WidgetTester t, Widget child) {
  useDifyTestTranslator();
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 360, child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('list-operator/sub-variable-picker', () {
    testWidgets('should render the placeholder and allow selecting a sub variable', (t) async {
      final changes = <String>[];
      await pumpControl(t, SubVariablePicker(value: '', onChange: changes.add));

      expect(find.text('common.placeholder.select'), findsOneWidget);
      await t.tap(find.text('common.placeholder.select'));
      await Harness.settle(t);
      await t.tap(find.text('name'));
      await Harness.settle(t);

      expect(changes, ['name']);
    });

    testWidgets('should render the selected value chip and update it from the options', (t) async {
      final changes = <String>[];
      await pumpControl(t, SubVariablePicker(value: 'size', onChange: changes.add));

      expect(find.text('size'), findsOneWidget);
      await t.tap(find.text('size'));
      await Harness.settle(t);
      await t.tap(find.text('type'));
      await Harness.settle(t);

      expect(changes, ['type']);
    });
  });
}
