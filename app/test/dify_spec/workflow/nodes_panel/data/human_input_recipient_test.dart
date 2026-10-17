// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/recipient/__tests__/index.spec.tsx
//
// The real selector and email input (the spec mocks them).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

const accounts = [
  HiMember(id: 'member-1', email: 'member-1@example.com', name: 'Member One'),
  HiMember(id: 'member-2', email: 'member-2@example.com', name: 'Member Two'),
  HiMember(id: 'member-3', email: 'member-3@example.com', name: 'Member Three'),
];

void main() {
  group('Recipient', () {
    testWidgets('should render workspace details and update recipients through member/email actions', (t) async {
      final changes = <Map<String, Object?>>[];
      const data = {
        'whole_workspace': false,
        'items': [
          {'type': 'member', 'user_id': 'member-1'},
          {'type': 'external', 'email': 'external@example.com'},
        ],
      };
      await pumpComponent(
        t,
        Recipient(data: data, onChange: changes.add),
        wrap: (c) => host(c, list: accounts),
        width: 800,
      );
      Finder field() =>
          find.descendant(of: find.byKey(const ValueKey('email-input')), matching: find.byType(EditableText));

      expect(find.text('D'), findsOneWidget);
      expect(find.textContaining('Dify’s Lab'), findsOneWidget);

      await tapAndSettle(
        t,
        find.widgetWithText(DifyButton, hiKey('deliveryMethod.emailConfigure.memberSelector.trigger')),
      );
      await tapAndSettle(t, find.text('Member Two').last);
      await t.tap(find.byKey(const ValueKey('email-input-box')));
      await t.enterText(field(), 'new@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.enterText(field(), 'member-3@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await tapNamed(t, 'common.operation.remove');
      await t.tap(named('common.operation.remove').last);
      await t.pump();
      await t.tap(find.byType(DifySwitch));
      await t.pump();

      List<Object?> items(int i) => changes[i]['items']! as List<Object?>;
      expect(items(0).last, {'type': 'member', 'user_id': 'member-2'});
      expect(items(1).last, {'type': 'external', 'email': 'new@example.com'});
      expect(items(2).last, {'type': 'member', 'user_id': 'member-3'});
      expect(items(3), [
        {'type': 'external', 'email': 'external@example.com'},
      ]);
      expect(items(4), [
        {'type': 'member', 'user_id': 'member-1'},
      ]);
      expect(changes[5], {...data, 'whole_workspace': true});
    });
  });
}
