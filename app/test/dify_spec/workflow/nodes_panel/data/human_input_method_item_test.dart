// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/method-item.spec.tsx
//
// The real configure modal and test sender (the spec mocks them); the row's actions show on hover.
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/test_email_sender.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

Map<String, Object?> createEmailConfig([Map<String, Object?> overrides = const {}]) => {
  'recipients': {
    'whole_workspace': false,
    'items': [
      {'type': 'external', 'email': 'test@example.com'},
    ],
  },
  'subject': 'Hello',
  'body': '{{#url#}}',
  'debug_mode': false,
  ...overrides,
};

const email = EmailContext(nodeId: 'node-1', formContent: 'Hello {{#url#}}');

void main() {
  late List<Map<String, Object?>> changes;
  late List<String> deletes;

  setUp(() {
    changes = [];
    deletes = [];
  });

  Widget item(Map<String, Object?> method, {bool readonly = false}) => MethodItem(
    method: method,
    email: email,
    readonly: readonly,
    onChange: changes.add,
    onDelete: deletes.add,
  );

  Finder row(String type) => find.byKey(ValueKey('method-row-$type'));
  BoxDecoration rowLook(WidgetTester t, String type) => t.widget<Container>(row(type)).decoration! as BoxDecoration;

  group('human-input/delivery-method/method-item', () {
    testWidgets('should toggle and delete a webapp delivery method', (t) async {
      await pumpComponent(t, item({'id': 'webapp-1', 'type': 'webapp', 'enabled': true}));

      await t.tap(find.byType(DifySwitch));
      await t.pump();
      expect(changes.single, {'id': 'webapp-1', 'type': 'webapp', 'enabled': false});

      final g = await hover(t, row('webapp'));
      await g.moveTo(t.getCenter(iconButton('common.operation.remove')));
      await t.pump();
      expect((rowLook(t, 'webapp').border! as Border).top.color, DifyColors.stateDestructiveBorder);
      await g.moveTo(t.getTopLeft(row('webapp')) + const Offset(4, 4));
      await t.pump();
      expect((rowLook(t, 'webapp').border! as Border).top.color, isNot(DifyColors.stateDestructiveBorder));

      await t.tap(iconButton('common.operation.remove'));
      expect(deletes, ['webapp']);
    });

    testWidgets('should open configure and test flows for an email method with config', (t) async {
      final method = {
        'id': 'email-1',
        'type': 'email',
        'enabled': true,
        'config': createEmailConfig({'debug_mode': true}),
      };
      await pumpComponent(t, item(method));
      expect(find.text('DEBUG'), findsOneWidget);

      await hover(t, row('email'));
      final sendTip = '${hiKey('deliveryMethod.emailSender.testSendTipInDebugMode')}:{"email":"owner@example.com"}';
      await tapAndSettle(t, iconButton(sendTip));
      expect(find.byType(TestEmailSender), findsOneWidget);
      await tapAndSettle(t, iconButton('common.operation.close'));
      expect(find.byType(TestEmailSender), findsNothing);

      await tapAndSettle(t, iconButton('workflow.common.configure'));
      expect(find.byType(EmailConfigureModal), findsOneWidget);
      await tapAndSettle(t, iconButton('common.operation.close'));
      expect(find.byType(EmailConfigureModal), findsNothing);

      await tapAndSettle(t, iconButton('workflow.common.configure'));
      await t.enterText(inputNamed(hiKey('deliveryMethod.emailConfigure.subject')), 'Configured subject');
      await tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.save'));
      expect(changes.single['config'], containsPair('subject', 'Configured subject'));

      await hover(t, row('email'));
      await t.tap(iconButton('common.operation.remove'));
      expect(deletes, ['email']);
    });

    testWidgets('should open email config from the unconfigured button and from the test sender jump action', (
      t,
    ) async {
      await pumpComponent(t, item({'id': 'email-2', 'type': 'email', 'enabled': false}));
      await tapAndSettle(t, find.widgetWithText(DifyButton, hiKey('deliveryMethod.notConfigured')));
      expect(find.byType(EmailConfigureModal), findsOneWidget);
      await tapAndSettle(t, iconButton('common.operation.close'));
      expect(find.byType(EmailConfigureModal), findsNothing);

      // The jump: the test sender's "enable Debug Mode" link opens the configuration.
      await pumpComponent(t, item({'id': 'email-3', 'type': 'email', 'enabled': true, 'config': createEmailConfig()}));
      await hover(t, row('email'));
      DifyI18n.current = EnglishFor({
        'nodes.humanInput.deliveryMethod.emailSender.tip':
            'It is recommended to <strong>enable Debug Mode</strong> for testing email delivery.',
      });
      await tapAndSettle(t, iconButton(hiKey('deliveryMethod.emailSender.testSendTip')));
      await tapAndSettle(t, find.text('enable Debug Mode'));
      expect(find.byType(TestEmailSender), findsNothing);
      expect(find.byType(EmailConfigureModal), findsOneWidget);
    });

    testWidgets('should keep actions disabled in readonly mode', (t) async {
      await pumpComponent(
        t,
        item({'id': 'email-3', 'type': 'email', 'enabled': true, 'config': createEmailConfig()}, readonly: true),
      );
      await t.tap(find.byType(DifySwitch));
      await t.pump();
      await hover(t, row('email'));

      expect(changes, isEmpty);
      expect(iconButton('workflow.common.configure'), findsNothing);
      expect(find.byType(EmailConfigureModal), findsNothing);
      expect(find.byType(TestEmailSender), findsNothing);
    });
  });
}
