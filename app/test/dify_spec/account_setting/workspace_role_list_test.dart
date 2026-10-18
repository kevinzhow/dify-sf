// dify-spec: web/app/components/header/account-setting/__tests__/workspace-role-checkbox-list.spec.tsx
//
// dify-sf gives each member one role (Dify's `allowMultipleRoles={false}`): the list is the radio form.
import 'dart:ui' show CheckedState, Tristate;

import 'package:dify_sf_app/src/settings/members/assign_roles_modal.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart';

const _roles = [
  WorkspaceRole(id: 'role-1', name: 'First role', isBuiltin: false),
  WorkspaceRole(id: 'role-2', name: 'Second role', isBuiltin: false),
];

Future<void> _render(
  WidgetTester t, {
  List<WorkspaceRole> roles = _roles,
  List<String> selected = const ['role-1'],
  List<String> disabled = const [],
}) => renderMembers(
  t,
  Center(
    child: SizedBox(
      width: 480,
      height: 400,
      child: WorkspaceRoleList(
        roles: roles,
        selectedRoleIds: selected,
        disabledRoleIds: disabled,
        onSelectedRolesChange: (_) {},
      ),
    ),
  ),
);

SemanticsData _radio(WidgetTester t, String id) =>
    t.getSemantics(find.byKey(ValueKey('role-radio-$id'))).getSemanticsData();

void main() {
  group('WorkspaceRoleCheckboxList', () {
    testWidgets('should render radios when only one role is allowed', (t) async {
      await _render(t);
      final first = _radio(t, 'role-1'), second = _radio(t, 'role-2');
      expect(first.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(first.flagsCollection.isChecked, CheckedState.isTrue);
      expect(second.flagsCollection.isChecked, isNot(CheckedState.isTrue));
      expect(first.label, contains('First role'));
    });

    testWidgets('should clear the role search and return focus to the search input', (t) async {
      await _render(t, selected: const []);
      final search = find.descendant(
        of: find.byWidgetPredicate((w) => w.runtimeType.toString() == 'SelectorSearchInput'),
        matching: find.byType(EditableText),
      );
      await t.tap(search);
      await t.enterText(search, 'First');
      await t.pump();
      expect(find.byKey(const ValueKey('role-radio-role-2')), findsNothing);
      await tapButton(t, 'common.operation.clear');
      expect(t.widget<EditableText>(search).controller.text, '');
      expect(t.widget<EditableText>(search).focusNode.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('role-radio-role-2')), findsOneWidget);
    });

    testWidgets('should expose disabled state on single-role options', (t) async {
      await _render(t, disabled: const ['role-1']);
      expect(_radio(t, 'role-1').flagsCollection.isEnabled, Tristate.isFalse);
      expect(_radio(t, 'role-2').flagsCollection.isEnabled, Tristate.isTrue);
    });

    testWidgets('should show legacy role descriptions when only one role is allowed', (t) async {
      await _render(
        t,
        selected: const ['editor'],
        roles: const [
          WorkspaceRole(id: 'admin', name: 'admin', isBuiltin: false),
          WorkspaceRole(id: 'editor', name: 'editor', isBuiltin: false),
          WorkspaceRole(id: 'normal', name: 'normal', isBuiltin: false),
          WorkspaceRole(id: 'dataset_operator', name: 'dataset_operator', isBuiltin: false),
        ],
      );
      expect(find.text('common.members.adminTip'), findsOneWidget);
      expect(find.text('common.members.editorTip'), findsOneWidget);
      expect(find.text('common.members.normalTip'), findsOneWidget);
      expect(find.text('common.members.datasetOperatorTip'), findsOneWidget);
      expect(find.text('permission.role.noDescription'), findsNothing);
    });
  });
}
