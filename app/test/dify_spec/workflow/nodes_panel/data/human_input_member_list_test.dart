// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/recipient/__tests__/member-list.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

const list = [
  HiMember(id: 'member-1', email: 'owner@example.com', name: 'Owner'),
  HiMember(id: 'member-2', email: 'pending@example.com', name: 'Pending User', status: 'pending'),
];

void main() {
  late List<String> selects;
  setUp(() => selects = []);

  group('human-input/delivery-method/recipient/member-list', () {
    testWidgets('should filter members, show selected state, and only add unselected members', (t) async {
      final searches = <String>[];
      var search = 'pending';
      await pumpComponent(
        t,
        StatefulBuilder(
          builder: (context, setState) => MemberList(
            value: const [
              {'type': 'member', 'user_id': 'member-1'},
            ],
            searchValue: search,
            list: list,
            email: 'owner@example.com',
            onSelect: selects.add,
            onSearchChange: (v) => setState(() {
              search = v;
              searches.add(v);
            }),
          ),
        ),
      );
      final box = inputNamed('common.operation.search');
      await t.enterText(box, 'owner');
      await t.pump();
      expect(searches, contains('owner'));
      expect(find.textContaining('Owner'), findsOneWidget);
      expect(find.text(hiKey('deliveryMethod.emailConfigure.memberSelector.add')), findsNothing);

      await t.enterText(box, 'pending');
      await t.pump();
      expect(find.textContaining('Pending User'), findsOneWidget);
      expect(find.textContaining('common.members.pending'), findsOneWidget);
      await t.tap(find.textContaining('Pending User'));
      expect(selects, ['member-2']);
    });

    testWidgets(
      'should show selected members as added, mark the current user, and return null when hideSearch has no matches',
      (t) async {
        Widget memberList(List<Object?> value, String search) => MemberList(
          value: value,
          searchValue: search,
          list: list,
          email: 'owner@example.com',
          hideSearch: true,
          onSelect: selects.add,
        );
        await pumpComponent(
          t,
          memberList(const [
            {'type': 'member', 'user_id': 'member-1'},
          ], ''),
        );
        expect(find.textContaining('common.members.you'), findsOneWidget);
        expect(find.text(hiKey('deliveryMethod.emailConfigure.memberSelector.added')), findsOneWidget);
        await t.tap(find.textContaining('Owner'));
        expect(selects, isEmpty);

        await pumpComponent(t, memberList(const [], 'missing'));
        expect(find.textContaining('Owner'), findsNothing);
        expect(find.textContaining('Pending User'), findsNothing);
      },
    );
  });
}
