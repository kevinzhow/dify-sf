// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/timeout.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<(num, String)> changes;
  setUp(() => changes = []);

  Finder field() => find.descendant(of: find.byType(DifyNumberField), matching: find.byType(EditableText));

  group('TimeoutInput', () {
    testWidgets('should update the timeout with the keyboard and switch units', (t) async {
      await pumpComponent(
        t,
        TimeoutInput(timeout: 3, unit: 'day', onChange: (v, u) => changes.add((v, u))),
        width: 1300,
      );
      await t.tap(field());
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tapNamed(t, hiKey('timeout.hours'));

      expect(changes, [(4, 'day'), (3, 'hour')]);
    });

    testWidgets('should fall back to 1 when cleared and stay read-only when disabled', (t) async {
      await pumpComponent(
        t,
        TimeoutInput(timeout: 5, unit: 'hour', onChange: (v, u) => changes.add((v, u))),
        width: 1300,
      );
      await t.enterText(field(), '');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(changes, [(1, 'hour')]);

      await pumpComponent(
        t,
        TimeoutInput(timeout: 5, unit: 'hour', readonly: true, onChange: (v, u) => changes.add((v, u))),
        width: 1300,
      );
      await tapNamed(t, hiKey('timeout.days'));
      expect(changes, hasLength(1));
      expect(t.widget<DifyNumberField>(find.byType(DifyNumberField)).disabled, isTrue);
      expect(t.widget<DifySegmentedControl<String>>(find.byType(DifySegmentedControl<String>)).disabled, isTrue);
    });
  });
}
