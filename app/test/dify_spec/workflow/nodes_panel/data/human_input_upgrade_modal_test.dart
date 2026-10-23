// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/upgrade-modal.spec.tsx
//
// The pricing page is the host's (HumanInputHost.onUpgrade).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  testWidgets('renders upgrade copy and handles hide and pricing actions', (t) async {
    var upgrades = 0;
    await pumpComponent(
      t,
      Opener<void>(results: [], open: showUpgradeModal),
      isCloud: true,
      wrap: (c) => host(c, onUpgrade: () => upgrades++),
    );
    await tapAndSettle(t, find.text('open'));
    expect(find.text(hiKey('deliveryMethod.upgradeTipContent')), findsOneWidget);

    await tapAndSettle(t, find.text('billing.upgradeBtn.encourageShort'));
    expect(upgrades, 1);

    await tapAndSettle(t, find.widgetWithText(DifyButton, hiKey('deliveryMethod.upgradeTipHide')));
    expect(find.text(hiKey('deliveryMethod.upgradeTipContent')), findsNothing);
  });
}
