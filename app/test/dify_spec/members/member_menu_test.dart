// dify-spec: web/app/components/header/account-setting/members-page/__tests__/member-menu.spec.tsx
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/settings/members/member_menu.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _roles = [
  WorkspaceRole(id: 'role-1', name: 'First role', isBuiltin: false),
  WorkspaceRole(id: 'role-2', name: 'Second role', isBuiltin: false),
];

const _member = Member(
  id: 'member-1',
  name: 'Member User',
  email: 'member@example.com',
  role: 'role-1',
  status: 'active',
);

Future<void> _openMenu(WidgetTester t) async {
  await tapButton(t, 'common.members.memberActions');
}

void main() {
  group('MemberMenu', () {
    testWidgets('should show edit role copy when multiple roles are disabled', (t) async {
      await renderMembers(
        t,
        Center(
          child: MemberMenu(
            member: _member,
            isCurrentUser: false,
            roles: _roles,
            onUpdateRole: (_) async {},
            onRemove: () async {},
          ),
        ),
      );
      await _openMenu(t);
      expect(find.text('common.members.editRole'), findsOneWidget);
      expect(find.text('common.members.assignRoles'), findsNothing);
      await t.tap(find.byKey(const ValueKey('member-edit-role')));
      await settle(t);
      expect(find.semantics.byPredicate((n) => n.label == 'common.members.editRole'), findsWidgets);
      expect(find.byKey(const ValueKey('assign-confirm')), findsOneWidget);
    });

    testWidgets('should submit only one selected role from the assign modal when RBAC is disabled', (t) async {
      final updates = <String>[];
      await renderMembers(
        t,
        Center(
          child: MemberMenu(
            member: _member,
            isCurrentUser: false,
            roles: _roles,
            onUpdateRole: (r) async => updates.add(r),
            onRemove: () async {},
          ),
        ),
      );
      await _openMenu(t);
      await t.tap(find.byKey(const ValueKey('member-edit-role')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('role-radio-role-2')));
      await settle(t, 2);
      await t.tap(find.byKey(const ValueKey('assign-confirm')));
      await settle(t);
      expect(updates, ['role-2']);
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
    });

    testWidgets('should require confirmation before removing a member', (t) async {
      final f = await MembersFixture.create(more: [('member@example.com', 'Member User', AccountRole.normal)]);
      final member = f.members.members.firstWhere((m) => m.email == 'member@example.com');
      await renderMembers(
        t,
        Center(
          child: MemberMenu(
            member: member,
            isCurrentUser: false,
            onUpdateRole: (r) => f.members.updateRole(member.id, r),
            onRemove: () => f.members.remove(member.id),
          ),
        ),
      );
      await _openMenu(t);
      await t.tap(find.byKey(const ValueKey('member-remove')));
      await settle(t);

      expect(find.text('common.members.removeFromTeamConfirmTitle:{"memberName":"Member User"}'), findsOneWidget);
      expect(find.text('common.members.removeFromTeamConfirmDescription'), findsOneWidget);
      expect(f.accounts.byEmail('member@example.com')!.role, AccountRole.normal);

      await t.tap(find.byKey(const ValueKey('alert-confirm')));
      await settle(t);
      // Removed on the server, the list refetched, the success toast shown.
      expect(f.accounts.byEmail('member@example.com')!.role, isNull);
      expect(f.members.members.where((m) => m.email == 'member@example.com'), isEmpty);
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-dialog')), findsNothing);
    });
  });
}
