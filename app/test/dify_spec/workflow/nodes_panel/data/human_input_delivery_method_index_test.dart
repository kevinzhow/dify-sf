// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/index.spec.tsx
//
// The real selector and items (the spec mocks them). Dify syncs the draft after a change; dify-sf's edits are
// already shared ops, so there is no separate sync to check.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

const email = EmailContext(nodeId: 'node-1');

void main() {
  late List<List<Map<String, Object?>>> changes;
  setUp(() => changes = []);

  Widget form(List<Map<String, Object?>> value) =>
      DeliveryMethodForm(value: value, email: email, newId: () => 'email-1', onChange: changes.add);

  group('DeliveryMethodForm', () {
    testWidgets('should render the empty state and add methods through the selector', (t) async {
      await pumpComponent(t, form(const []));
      expect(find.text(hiKey('deliveryMethod.emptyTip')), findsOneWidget);

      await tapAndSettle(t, iconButton(hiKey('deliveryMethod.title')));
      await tapAndSettle(t, find.text(hiKey('deliveryMethod.types.email.title')));

      expect(changes, [
        [
          {'id': 'email-1', 'type': 'email', 'enabled': false},
        ],
      ]);
    });

    testWidgets('should change and delete methods, syncing the draft after updates', (t) async {
      final method = {
        'id': 'email-1',
        'type': 'email',
        'enabled': false,
        'config': {
          'recipients': {'whole_workspace': true, 'items': <Object?>[]},
          'subject': 'Hello',
          'body': '{{#url#}}',
          'debug_mode': false,
        },
      };
      await pumpComponent(t, form([method]));

      await t.tap(find.byType(DifySwitch));
      await t.pump();
      await hover(t, find.byKey(const ValueKey('method-row-email')));
      await tapAndSettle(t, iconButton('common.operation.remove'));

      expect(changes[0], [
        {...method, 'enabled': true},
      ]);
      expect(changes[1], isEmpty);
    });

    testWidgets('should open and close the upgrade modal', (t) async {
      await pumpComponent(t, form(const []), wrap: (c) => host(c, emailDeliveryEnabled: false));

      await tapAndSettle(t, iconButton(hiKey('deliveryMethod.title')));
      await tapAndSettle(t, find.text(hiKey('deliveryMethod.types.email.title')));
      expect(find.text(hiKey('deliveryMethod.upgradeTip')), findsOneWidget);

      await tapAndSettle(t, find.widgetWithText(DifyButton, hiKey('deliveryMethod.upgradeTipHide')));
      expect(find.text(hiKey('deliveryMethod.upgradeTip')), findsNothing);
      expect(changes, isEmpty);
    });
  });
}
