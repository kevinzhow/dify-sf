// dify-spec: web/app/components/header/account-setting/members-page/invite-modal/__tests__/invite-error.spec.ts
//
// dify-sf's client reports a refused request as a TransportException with the server's error code.
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/settings/members/email_recipients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getInviteErrorCode', () {
    test('reads the documented %s code from the contract error body', () {
      for (final code in ['invalid_param', 'invalid_role', 'limit_exceeded']) {
        expect(inviteErrorCode(TransportException('Backend message', statusCode: 400, code: code)), code);
      }
    });

    test('ignores transport and undocumented error codes', () {
      expect(inviteErrorCode(const TransportException('x', code: 'BAD_REQUEST')), isNull);
      expect(inviteErrorCode(const TransportException('x', statusCode: 400, code: 'invalid-role')), isNull);
      expect(inviteErrorCode(Exception('network')), isNull);
    });
  });
}
