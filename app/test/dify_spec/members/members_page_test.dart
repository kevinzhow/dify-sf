// dify-spec: web/app/components/header/account-setting/members-page/__tests__/index.spec.tsx
//
// Dify mocks the page's dialogs and menus; here they are the real ones, on the in-memory accounts server.
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/settings/members/members_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<MembersFixture> _render(
  WidgetTester t, {
  String as = 'owner@example.com',
  List<(String, String, String)> more = const [],
  String Function(int)? formatTimeFromNow,
}) async {
  final f = await MembersFixture.create(as: as, more: more);
  await renderMembers(
    t,
    SingleChildScrollView(
      child: MembersPage(members: f.members, formatTimeFromNow: formatTimeFromNow ?? (_) => 'just now'),
    ),
  );
  return f;
}

Finder _detailsButton(MembersFixture f, String email) => find.byKey(ValueKey('member-details-${f.idOf(email)}'));

void main() {
  group('MembersPage', () {
    testWidgets('should render workspace and member information', (t) async {
      await _render(t);
      expect(find.text("Owner User's Workspace"), findsOneWidget);
      expect(find.textContaining('Owner User', findRichText: true), findsWidgets);
      expect(find.textContaining('Admin User', findRichText: true), findsOneWidget);
    });

    testWidgets('should render fixed name column and flexible role column layout', (t) async {
      final f = await _render(t);
      final nameHead = find.ancestor(of: find.text('COMMON.MEMBERS.NAME'), matching: find.byType(SizedBox)).first;
      expect(t.getSize(nameHead).width, 260);
      final roleHead = find.ancestor(of: find.text('COMMON.MEMBERS.ROLE'), matching: find.byType(Expanded)).first;
      expect(t.getSize(roleHead).width, greaterThan(260));
      final row = _detailsButton(f, 'owner@example.com');
      final firstCell = find.descendant(of: row, matching: find.byType(SizedBox)).first;
      expect(t.getSize(firstCell).width, 260);
    });

    testWidgets('should open and close invite modal', (t) async {
      await _render(t);
      await tapButton(t, 'common.members.invite');
      expect(find.text('common.members.inviteTeamMember'), findsWidgets);
      await tapButton(t, 'common.operation.close');
      expect(find.text('common.members.inviteTeamMemberTip'), findsNothing);
    });

    testWidgets('should open invited modal after invite results are sent', (t) async {
      final f = await _render(t);
      await tapButton(t, 'common.members.invite');
      await t.enterText(find.byKey(const ValueKey('email-recipients-input')), 'sent@example.com');
      await settle(t);
      await t.tap(find.byKey(const ValueKey('role-selector-trigger')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('role-option-editor')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('send-invite')));
      await settle(t);
      expect(find.text('common.members.invitationSent'), findsOneWidget);
      expect(find.textContaining('/activate?email=sent%40example.com&token='), findsOneWidget);
      expect(f.accounts.byEmail('sent@example.com')!.role, AccountRole.editor);

      await t.tap(find.byKey(const ValueKey('invited-ok')));
      await settle(t);
      expect(find.text('common.members.invitationSent'), findsNothing);
      // The new member is listed, pending.
      expect(find.textContaining('common.members.pending', findRichText: true), findsOneWidget);
    });

    testWidgets('should show non-interactive owner role when transfer ownership is not allowed', (t) async {
      final f = await _render(t);
      expect(find.byKey(const ValueKey('role-badge-owner')), findsOneWidget);
      expect(find.byKey(ValueKey('member-actions-${f.idOf('owner@example.com')}')), findsNothing);
      expect(buttonMatching('common.members.transferOwnership'), findsNothing);
    });

    testWidgets('should hide manager controls for non-owner non-manager users', (t) async {
      await _render(t, as: 'editor@example.com', more: [('editor@example.com', 'Editor User', AccountRole.editor)]);
      expect(button('common.members.invite'), findsNothing);
      expect(button('common.members.memberActions'), findsNothing);
    });

    testWidgets('should show pending status and you indicator', (t) async {
      final f = await MembersFixture.create();
      await f.members.invite(emails: ['pending@example.com'], role: AccountRole.normal);
      await renderMembers(t, SingleChildScrollView(child: MembersPage(members: f.members)));
      expect(find.textContaining('common.members.pending', findRichText: true), findsOneWidget);
      expect(find.textContaining('common.members.you', findRichText: true), findsOneWidget);
    });

    testWidgets('should show invite button when user is manager but not owner', (t) async {
      await _render(t, as: 'admin@example.com');
      expect(button('common.members.invite'), findsOneWidget);
      expect(buttonMatching('common.members.transferOwnership'), findsNothing);
    });

    testWidgets('should allow admins to operate other non-owner members only', (t) async {
      final f = await _render(
        t,
        as: 'admin@example.com',
        more: [
          ('editor@example.com', 'Editor User', AccountRole.editor),
          ('normal@example.com', 'Normal User', AccountRole.normal),
          ('dataset@example.com', 'Dataset User', AccountRole.datasetOperator),
          ('other-admin@example.com', 'Other Admin User', AccountRole.admin),
        ],
      );
      Finder actions(String email) => find.byKey(ValueKey('member-actions-${f.idOf(email)}'));
      expect(actions('editor@example.com'), findsOneWidget);
      expect(actions('normal@example.com'), findsOneWidget);
      expect(actions('dataset@example.com'), findsOneWidget);
      expect(actions('other-admin@example.com'), findsOneWidget);
      expect(actions('owner@example.com'), findsNothing);
      expect(actions('admin@example.com'), findsNothing);
    });

    testWidgets('should use created_at as fallback when last_active_at is empty', (t) async {
      final calls = <int>[];
      final f = await MembersFixture.create();
      await f.members.invite(emails: ['new@example.com'], role: AccountRole.normal);
      await renderMembers(
        t,
        SingleChildScrollView(
          child: MembersPage(
            members: f.members,
            formatTimeFromNow: (ms) {
              calls.add(ms);
              return 'just now';
            },
          ),
        ),
      );
      final invited = f.accounts.byEmail('new@example.com')!;
      expect(invited.lastLoginAt, isNull);
      expect(calls, contains(invited.createdAt.millisecondsSinceEpoch));
    });

    testWidgets('should not show plural s when only one account in non-billing layout', (t) async {
      final f = await MembersFixture.create();
      await f.members.remove(f.idOf('admin@example.com'));
      await renderMembers(t, SingleChildScrollView(child: MembersPage(members: f.members)));
      expect(find.text('billing.plansCommon.memberAfter'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('should render role badge names from account roles', (t) async {
      await _render(t, as: 'editor@example.com', more: [('editor@example.com', 'Editor User', AccountRole.editor)]);
      expect(find.byKey(const ValueKey('role-badge-admin')), findsOneWidget);
      expect(find.text('admin'), findsOneWidget);
    });

    testWidgets('should expose member details as a native row button without nesting member actions', (t) async {
      final f = await _render(t);
      final details = button('common.members.memberDetails.openAria:{"name":"Admin User"}');
      expect(details, findsOneWidget);
      final menu = find.byKey(ValueKey('member-actions-${f.idOf('admin@example.com')}'));
      expect(menu, findsOneWidget);
      // The actions button is not inside the row's button.
      expect(find.descendant(of: _detailsButton(f, 'admin@example.com'), matching: menu), findsNothing);
    });

    testWidgets('should open member details modal when a member row is clicked', (t) async {
      final f = await _render(t);
      await t.tap(_detailsButton(f, 'admin@example.com'));
      await settle(t);
      expect(find.text('common.members.memberDetails.title'), findsOneWidget);
      expect(find.text('admin@example.com'), findsNWidgets(2));
      await tapButton(t, 'common.operation.close');
      expect(find.text('common.members.memberDetails.title'), findsNothing);
    });

    testWidgets('should open member details modal via keyboard Enter', (t) async {
      final f = await _render(t);
      final row = _detailsButton(f, 'admin@example.com');
      Focus.of(t.element(row)).requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(find.text('common.members.memberDetails.title'), findsOneWidget);
    });

    testWidgets('should not allow assigning roles from member details when target is owner', (t) async {
      final f = await _render(t);
      await t.tap(_detailsButton(f, 'owner@example.com'));
      await settle(t);
      expect(find.text('common.members.memberDetails.title'), findsOneWidget);
      expect(find.byKey(const ValueKey('details-edit-role')), findsNothing);
    });

    testWidgets('should not allow assigning roles from member details when target is current user', (t) async {
      final f = await _render(t, as: 'admin@example.com');
      await t.tap(_detailsButton(f, 'admin@example.com'));
      await settle(t);
      expect(find.byKey(const ValueKey('details-edit-role')), findsNothing);
    });

    testWidgets('should submit only one member role when RBAC is disabled', (t) async {
      final f = await _render(t);
      await t.tap(_detailsButton(f, 'admin@example.com'));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('details-edit-role')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('role-radio-normal')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('assign-confirm')));
      await settle(t);
      // Still pending: the details show the new role, the server has the old one.
      expect(find.byKey(const ValueKey('chip-normal')), findsOneWidget);
      expect(f.accounts.byEmail('admin@example.com')!.role, AccountRole.admin);
      await t.tap(find.byKey(const ValueKey('details-save')));
      await settle(t);
      expect(f.accounts.byEmail('admin@example.com')!.role, AccountRole.normal);
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      expect(find.byKey(const ValueKey('role-badge-normal')), findsOneWidget);
    });

    testWidgets('should not open member details when clicking the member menu area', (t) async {
      final f = await _render(t);
      await t.tap(find.byKey(ValueKey('member-actions-${f.idOf('admin@example.com')}')));
      await settle(t);
      expect(find.text('common.members.memberDetails.title'), findsNothing);
      expect(find.text('common.members.editRole'), findsOneWidget);
    });
  });
}
