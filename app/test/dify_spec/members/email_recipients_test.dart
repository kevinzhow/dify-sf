// dify-spec: web/app/components/header/account-setting/members-page/invite-modal/__tests__/email-recipients.spec.ts
import 'package:dify_sf_app/src/settings/members/email_recipients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('email recipients', () {
    test('should normalize an address while preserving browser email validity semantics', () {
      expect(createEmailRecipient('  Person@Example  '), const EmailRecipient('person@example', isValid: true));
      expect(createEmailRecipient('not-an-email'), const EmailRecipient('not-an-email', isValid: false));
    });

    test('should recognize %j as a batch paste separator', () {
      for (final separator in [',', ';', '\n', '\r\n', '\t']) {
        expect(hasEmailDelimiter('first@example.com${separator}second@example.com'), isTrue, reason: separator);
      }
    });

    test('should not treat %j as batch input', () {
      for (final value in ['first@example.com', 'first@example.com second@example.com']) {
        expect(hasEmailDelimiter(value), isFalse, reason: value);
      }
    });

    test('should ignore empty entries while preserving recipient order', () {
      expect(mergeEmailRecipients(const [], ' first@example.com, ,\nsecond@example.com;\t'), const [
        EmailRecipient('first@example.com', isValid: true),
        EmailRecipient('second@example.com', isValid: true),
      ]);
    });

    test('should deduplicate recipients against both existing and pasted addresses', () {
      final existing = [createEmailRecipient('first@example.com')];
      expect(mergeEmailRecipients(existing, 'FIRST@example.com, second@example.com, SECOND@example.com'), const [
        EmailRecipient('first@example.com', isValid: true),
        EmailRecipient('second@example.com', isValid: true),
      ]);
    });

    test('should preserve invalid pasted entries so the user can correct them', () {
      expect(mergeEmailRecipients(const [], 'valid@example.com, not-an-email'), const [
        EmailRecipient('valid@example.com', isValid: true),
        EmailRecipient('not-an-email', isValid: false),
      ]);
    });

    test('should preserve the order of a realistic twenty-recipient batch', () {
      final addresses = [for (var i = 0; i < 20; i++) 'person-${i + 1}@example.com'];
      expect([for (final r in mergeEmailRecipients(const [], addresses.join('\n'))) r.value], addresses);
    });
  });
}
