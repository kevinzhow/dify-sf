// dify-spec: web/app/components/header/account-setting/members-page/invite-modal/__tests__/role-selector.spec.tsx
//
// dify-sf's roles are Dify's built-in ones (no role query), given to the selector as a list.
import 'package:dify_sf_app/src/settings/members/role_selector.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _roles = [
  WorkspaceRole(id: 'admin', name: 'Admin', description: 'Can manage workspace settings'),
  WorkspaceRole(id: 'editor', name: 'Editor', description: 'Can build and edit apps'),
  WorkspaceRole(id: 'normal', name: 'Normal', description: 'Can use apps'),
];

class _Wrapper extends StatefulWidget {
  const _Wrapper({this.roles = _roles});
  final List<WorkspaceRole> roles;

  @override
  State<_Wrapper> createState() => _WrapperState();
}

class _WrapperState extends State<_Wrapper> {
  WorkspaceRole? value;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 432,
        child: RoleSelector(roles: widget.roles, value: value, onChanged: (r) => setState(() => value = r)),
      ),
    ),
  );
}

Finder get _trigger => find.byKey(const ValueKey('role-selector-trigger'));

String _triggerValue(WidgetTester t) => t.getSemantics(_trigger).getSemanticsData().value;

Future<void> _openList(WidgetTester t) async {
  await t.tap(_trigger);
  await settle(t, 3);
}

void main() {
  group('RoleSelector', () {
    testWidgets('requires an explicit selection and exposes select semantics', (t) async {
      await renderMembers(t, const _Wrapper());
      expect(_triggerValue(t), 'common.members.selectRole');
      expect(t.getSemantics(_trigger).label, 'common.members.role');
    });

    testWidgets('uses the selected Role object as its typed value', (t) async {
      await renderMembers(t, const _Wrapper());
      await _openList(t);
      await t.tap(find.byKey(const ValueKey('role-option-admin')));
      await settle(t, 3);
      expect(_triggerValue(t), 'Admin');
      expect(t.state<State<_Wrapper>>(find.byType(_Wrapper)), isA<_WrapperState>());
      expect((t.state(find.byType(_Wrapper)) as _WrapperState).value?.id, 'admin');
    });

    testWidgets('shows role descriptions in the option list', (t) async {
      await renderMembers(t, const _Wrapper());
      await _openList(t);
      expect(find.text('Can manage workspace settings'), findsOneWidget);
    });

    testWidgets('falls back to localized descriptions for legacy built-in roles', (t) async {
      await renderMembers(
        t,
        const _Wrapper(
          roles: [
            WorkspaceRole(id: 'admin', name: 'admin'),
            WorkspaceRole(id: 'dataset_operator', name: 'dataset_operator'),
          ],
        ),
      );
      await _openList(t);
      expect(find.text('common.members.adminTip'), findsOneWidget);
      expect(find.text('common.members.datasetOperatorTip'), findsOneWidget);
    });
  });
}
