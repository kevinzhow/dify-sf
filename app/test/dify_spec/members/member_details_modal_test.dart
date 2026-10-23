// dify-spec: web/app/components/header/account-setting/members-page/member-details-modal/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/settings/members/member_details_modal.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _custom = WorkspaceRole(id: 'role-1', name: 'Custom role', isBuiltin: false);
const _second = WorkspaceRole(id: 'role-2', name: 'Second role', isBuiltin: false);
const _member = Member(id: 'member-1', name: 'Admin User', email: 'admin@example.com', role: 'admin', status: 'active');

Future<void> _render(
  WidgetTester t, {
  bool canAssignRoles = true,
  ValueChanged<List<WorkspaceRole>>? onAssignSubmit,
}) => renderMembers(
  t,
  Center(
    child: MemberDetailsModal(
      member: _member,
      roles: const [_custom, _second],
      memberRoles: const [_custom],
      canAssignRoles: canAssignRoles,
      onAssignSubmit: onAssignSubmit ?? (_) {},
      onClose: () {},
    ),
  ),
);

void main() {
  group('MemberDetailsModal', () {
    group('Rendering', () {
      testWidgets('should render edit role action when multiple roles are disabled', (t) async {
        await _render(t);
        expect(button('common.operation.edit'), findsOneWidget);
        expect(button('common.members.memberDetails.assign'), findsNothing);
        final edit = find.byKey(const ValueKey('details-edit-role'));
        expect(
          find.descendant(of: edit, matching: find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'edit-line')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: edit, matching: find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'add-line')),
          findsNothing,
        );
      });

      testWidgets('should render singular assigned role label when there is one role', (t) async {
        await _render(t);
        expect(find.text('common.members.memberDetails.assignedRole'), findsOneWidget);
        expect(find.text('common.members.memberDetails.assignedRoles'), findsNothing);
      });
    });

    group('Role actions', () {
      testWidgets('should keep role chips readonly when multiple roles are disabled', (t) async {
        await _render(t);
        expect(button('Custom role'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('chip-role-1')));
        await settle(t, 2);
        expect(buttonMatching('common.operation.remove'), findsNothing);
      });

      testWidgets('should not show role removal controls when role assignment is not allowed', (t) async {
        await _render(t, canAssignRoles: false);
        expect(button('common.operation.edit'), findsNothing);
        expect(button('common.members.memberDetails.assign'), findsNothing);
        expect(buttonMatching('common.members.memberDetails.removeRoleAria'), findsNothing);
      });

      testWidgets('should replace the selected role when multiple roles are not allowed', (t) async {
        final submitted = <List<WorkspaceRole>>[];
        await _render(t, onAssignSubmit: submitted.add);
        await t.tap(find.byKey(const ValueKey('details-edit-role')));
        await settle(t);
        await t.tap(find.byKey(const ValueKey('role-radio-role-2')));
        await settle(t, 2);
        await t.tap(find.byKey(const ValueKey('assign-confirm')));
        await settle(t);
        expect(submitted, isEmpty);
        await t.tap(find.byKey(const ValueKey('details-save')));
        await settle(t);
        expect(submitted, [
          [_second],
        ]);
      });
    });
  });
}
