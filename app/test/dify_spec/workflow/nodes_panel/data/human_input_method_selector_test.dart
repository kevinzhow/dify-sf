// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/method-selector.spec.tsx
//
// Trigger mode is the panel's `isTriggerWorkflow` of the document's node types (passed in here).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<Map<String, Object?>> adds;
  late int upgrades;

  setUp(() {
    adds = [];
    upgrades = 0;
  });

  Widget selector(List<Map<String, Object?>> data, {bool trigger = false}) => Align(
    alignment: Alignment.topRight,
    child: MethodSelector(
      data: data,
      isTriggerMode: trigger,
      newId: () => 'generated-id',
      onAdd: adds.add,
      onShowUpgradeTip: () => upgrades++,
    ),
  );

  Future<void> open(WidgetTester t) => tapAndSettle(t, iconButton(hiKey('deliveryMethod.title')));

  group('human-input/delivery-method/method-selector', () {
    testWidgets('should add webapp and email delivery methods when both entries are available', (t) async {
      expect(isTriggerWorkflow(['start', 'llm']), isFalse);
      await pumpComponent(t, selector(const []), isCloud: true);
      await open(t);
      await t.tap(find.text(hiKey('deliveryMethod.types.webapp.title')));
      await t.pump();
      await t.tap(find.text(hiKey('deliveryMethod.types.email.title')));
      await t.pump();

      expect(adds, [
        {'id': 'generated-id', 'type': 'webapp', 'enabled': true},
        {'id': 'generated-id', 'type': 'email', 'enabled': false},
      ]);
      expect(upgrades, 0);
      expect(find.text(hiKey('deliveryMethod.contactTip1')), findsOneWidget);
      expect(find.textContaining(hiKey('deliveryMethod.contactTip2')), findsOneWidget);
    });

    testWidgets('should disable webapp in trigger mode and show added states without creating duplicates', (t) async {
      expect(isTriggerWorkflow(['trigger-webhook']), isTrue);
      await pumpComponent(
        t,
        selector(const [
          {'id': 'webapp-1', 'type': 'webapp', 'enabled': true},
          {'id': 'email-1', 'type': 'email', 'enabled': false},
        ], trigger: true),
      );
      await open(t);
      expect(find.text(hiKey('deliveryMethod.added')), findsNWidgets(2));

      await t.tap(find.text(hiKey('deliveryMethod.types.webapp.title')));
      await t.tap(find.text(hiKey('deliveryMethod.types.email.title')));
      await t.pump();
      expect(adds, isEmpty);
    });

    testWidgets('should show trigger-mode and permission guards for unavailable methods', (t) async {
      expect(isTriggerWorkflow(['trigger-schedule']), isTrue);
      await pumpComponent(
        t,
        selector(const [], trigger: true),
        wrap: (c) => host(c, emailDeliveryEnabled: false),
      );
      await open(t);
      expect(find.text(hiKey('deliveryMethod.notAvailableInTriggerMode')), findsOneWidget);

      await t.tap(find.text(hiKey('deliveryMethod.types.webapp.title')));
      await t.pump();
      expect(find.text('COMING SOON'), findsNWidgets(3));
      await t.tap(find.text(hiKey('deliveryMethod.types.email.title')));
      await t.pump();

      expect(adds, isEmpty);
      expect(upgrades, 1);
    });
  });
}
