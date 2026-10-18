// dify-spec: web/app/components/header/account-setting/members-page/invited-modal/__tests__/index.spec.tsx
//
// dify-sf's server sends no mail, like Dify's community edition: the community cases apply.
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/settings/members/invited_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _results = [
  InvitationResult(email: 'success@example.com', status: 'success', url: 'http://invite.com/1'),
  InvitationResult(email: 'member@example.com', status: 'already_member', message: 'Account already in workspace.'),
  InvitationResult(email: 'failed@example.com', status: 'failed', message: 'Error msg'),
];

Future<void> _render(WidgetTester t, List<InvitationResult> results) => renderMembers(
  t,
  Builder(
    builder: (context) => Center(
      child: InvitedModal(invitationResults: results, onCancel: () {}),
    ),
  ),
);

void main() {
  group('InvitedModal', () {
    testWidgets('should show success and failed invitation sections', (t) async {
      await _render(t, _results);
      expect(find.text('common.members.invitationSent'), findsOneWidget);
      expect(find.text('common.members.invitationLink'), findsOneWidget);
      expect(find.text('http://invite.com/1'), findsOneWidget);
      expect(find.text('common.members.alreadyInTeam'), findsOneWidget);
      expect(find.text('member@example.com'), findsOneWidget);
      expect(find.text('failed@example.com'), findsOneWidget);
    });

    testWidgets('should hide invitation link section when there are no successes', (t) async {
      await _render(t, const [
        InvitationResult(email: 'fail@example.com', status: 'failed', message: 'Quota exceeded'),
      ]);
      expect(find.text('common.members.invitationLink'), findsNothing);
      expect(find.text('common.members.failedInvitationEmails'), findsOneWidget);
    });

    testWidgets('should hide failed section when there are only successes', (t) async {
      await _render(t, const [
        InvitationResult(email: 'ok@example.com', status: 'success', url: 'http://invite.com/2'),
      ]);
      expect(find.text('common.members.invitationLink'), findsOneWidget);
      expect(find.text('common.members.failedInvitationEmails'), findsNothing);
    });

    testWidgets(
      'should show already-member message without invitation copy when every email is already a member',
      (t) async {
        await _render(t, const [
          InvitationResult(
            email: 'member@example.com',
            status: 'already_member',
            message: 'Account already in workspace.',
          ),
        ]);
        expect(find.text('common.members.noNewInvitationsSent'), findsOneWidget);
        expect(find.text('common.members.alreadyInTeamTip'), findsOneWidget);
        expect(find.text('member@example.com'), findsOneWidget);
        expect(find.text('common.members.invitationLink'), findsNothing);
      },
    );

    testWidgets('should hide both sections when results are empty', (t) async {
      await _render(t, const []);
      expect(find.text('common.members.invitationLink'), findsNothing);
      expect(find.text('common.members.failedInvitationEmails'), findsNothing);
    });
  });
}
