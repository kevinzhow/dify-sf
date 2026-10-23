// dify-spec: web/app/components/header/account-setting/members-page/__tests__/invite-button.spec.tsx
//
// Dify's invite button waits for the workspace permissions only with branding enabled (enterprise); dify-sf has no
// branding, so managers always see it (the MembersPage's "Add" button).
import 'package:dify_sf_app/src/settings/members/members_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('InviteButton', () {
    testWidgets('should show invite button when branding is disabled', (t) async {
      final f = await MembersFixture.create();
      await renderMembers(t, SingleChildScrollView(child: MembersPage(members: f.members)));
      expect(button('common.members.invite'), findsOneWidget);
    });
  });
}
