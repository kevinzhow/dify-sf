// dify-spec: web/app/components/header/account-setting/members-page/invited-modal/__tests__/invitation-link.spec.tsx
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/settings/members/invited_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _value = InvitationResult(email: 'test@example.com', status: 'success', url: '/invite/123');

Widget _link(InvitationResult value, List<String> copied, {String? origin}) => Center(
  child: SizedBox(
    width: 416,
    child: InvitationLink(value: value, origin: origin, copy: (text) async => copied.add(text)),
  ),
);

void main() {
  group('InvitationLink', () {
    testWidgets('should copy relative url with origin', (t) async {
      final copied = <String>[];
      await renderMembers(t, _link(_value, copied, origin: 'http://localhost:3000'));
      await tapButton(t, 'appApi.copy');
      expect(copied, ['http://localhost:3000/invite/123']);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('should copy absolute url as is', (t) async {
      final copied = <String>[];
      const absolute = InvitationResult(
        email: 'test@example.com',
        status: 'success',
        url: 'https://dify.ai/invite/123',
      );
      await renderMembers(t, _link(absolute, copied));
      await tapButton(t, 'https://dify.ai/invite/123');
      expect(copied, ['https://dify.ai/invite/123']);
      await t.pump(const Duration(seconds: 2));
    });
  });
}
