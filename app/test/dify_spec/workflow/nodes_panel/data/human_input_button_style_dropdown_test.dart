// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/button-style-dropdown.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<String> changes;
  setUp(() => changes = []);

  group('ButtonStyleDropdown', () {
    testWidgets('should open the style picker and update the selected style', (t) async {
      await pumpComponent(t, ButtonStyleDropdown(text: 'Approve', value: 'ghost', onChange: changes.add));

      await tapNamed(t, hiKey('userActions.chooseStyle'));
      expect(find.text(hiKey('userActions.chooseStyle')), findsOneWidget);
      await tapNamed(t, 'Approve');

      expect(changes, ['primary']);
    });

    testWidgets('should keep the dropdown closed in readonly mode', (t) async {
      await pumpComponent(
        t,
        ButtonStyleDropdown(text: 'Approve', value: 'default', readonly: true, onChange: changes.add),
      );

      await tapNamed(t, hiKey('userActions.chooseStyle'));

      expect(find.text(hiKey('userActions.chooseStyle')), findsNothing);
      expect(changes, isEmpty);
    });
  });
}
