// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/recipient/__tests__/member-selector.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<String> selects;
  setUp(() => selects = []);

  Finder trigger() => find.widgetWithText(DifyButton, hiKey('deliveryMethod.emailConfigure.memberSelector.trigger'));

  group('human-input/delivery-method/recipient/member-selector', () {
    testWidgets('should toggle the member list and forward selection props', (t) async {
      await pumpComponent(
        t,
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 120,
            child: MemberSelector(
              value: const [
                {'type': 'member', 'user_id': 'member-1'},
              ],
              email: 'owner@example.com',
              list: members,
              onSelect: selects.add,
            ),
          ),
        ),
      );
      expect(find.byType(MemberList), findsNothing);

      await tapAndSettle(t, trigger());
      final list = t.widget<MemberList>(find.byType(MemberList));
      expect((list.searchValue, list.list, list.email), ('', members, 'owner@example.com'));

      await tapAndSettle(t, trigger());
      expect(find.byType(MemberList), findsNothing);
    });

    testWidgets('should update search value and close the list after selecting a member', (t) async {
      await pumpComponent(
        t,
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 120,
            child: MemberSelector(value: const [], email: 'owner@example.com', list: members, onSelect: selects.add),
          ),
        ),
      );
      await tapAndSettle(t, trigger());
      await t.enterText(inputNamed('common.operation.search'), 'member one');
      await t.pump();
      expect(t.widget<MemberList>(find.byType(MemberList)).searchValue, 'member one');

      await tapAndSettle(t, find.text('Member One'));
      expect(selects, ['member-1']);
      expect(find.byType(MemberList), findsNothing);
    });
  });
}
