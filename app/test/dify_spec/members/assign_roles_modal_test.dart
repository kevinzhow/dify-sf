// dify-spec: web/app/components/header/account-setting/members-page/assign-roles-modal/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/settings/members/assign_roles_modal.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _roles = [
  WorkspaceRole(id: 'role-1', name: 'First role', isBuiltin: false),
  WorkspaceRole(id: 'role-2', name: 'Second role', isBuiltin: false),
];

Future<void> _render(WidgetTester t) => renderMembers(
  t,
  Center(
    child: AssignRolesModal(selectedRoles: [_roles[0]], roles: _roles),
  ),
);

void main() {
  group('AssignRolesModal', () {
    group('Role selection', () {
      testWidgets('should hide selected count when multiple roles are disabled', (t) async {
        await _render(t);
        expect(find.textContaining('common.members.assignRolesModal.selectedCount'), findsNothing);
      });

      testWidgets('should show single-role description when multiple roles are disabled', (t) async {
        await _render(t);
        expect(find.text('common.members.assignRolesModal.singleDescription'), findsOneWidget);
        expect(find.text('common.members.assignRolesModal.description'), findsNothing);
      });
    });
  });
}
