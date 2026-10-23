// dify-spec: web/app/components/workflow/nodes/list-operator/components/__tests__/limit-config.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'list_operator_sub_variable_picker_test.dart' show pumpControl;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

void main() {
  group('list-operator/limit-config', () {
    testWidgets('should enable limit mode from a disabled config', (t) async {
      final changes = <Map<String, Object?>>[];
      await pumpControl(t, LimitConfig(config: const {'enabled': false, 'size': 10}, onChange: changes.add));

      expect(find.text('WORKFLOW.NODES.LISTFILTER.LIMIT'), findsOneWidget);
      expect(find.byType(InputNumberWithSlider), findsNothing);

      await t.tap(find.byType(DifySwitch));
      await Harness.settle(t);
      expect(changes, [
        {'enabled': true, 'size': 10},
      ]);
    });

    testWidgets('should change the limit size and disable toggling when readonly', (t) async {
      final changes = <Map<String, Object?>>[];
      await pumpControl(
        t,
        LimitConfig(config: const {'enabled': true, 'size': 6}, readonly: true, onChange: changes.add),
      );

      final slider = t.widget<InputNumberWithSlider>(find.byType(InputNumberWithSlider));
      expect(slider.value, 6);
      expect(slider.min, 1);
      expect(slider.max, 20);
      expect(slider.readonly, true);
      expect(slider.label, 'workflow.nodes.listFilter.limit');

      slider.onChange(7);
      expect(changes, [
        {'enabled': true, 'size': 7},
      ]);

      await t.tap(find.byType(DifySwitch));
      await Harness.settle(t);
      expect(changes, hasLength(1));
    });
  });
}
