// dify-spec: web/app/components/header/account-setting/members-page/__tests__/role-badges.spec.tsx
import 'package:dify_sf_app/src/settings/members/member_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('RoleBadges', () {
    testWidgets('shows the visible roles and summarizes overflow', (t) async {
      await renderMembers(t, const Center(child: RoleBadges(roleNames: ['Owner', 'Admin', 'Editor'], max: 2)));
      expect(find.byKey(const ValueKey('role-badge-Owner')), findsOneWidget);
      expect(find.byKey(const ValueKey('role-badge-Admin')), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.byKey(const ValueKey('role-badge-Editor')), findsNothing);
    });
  });
}
