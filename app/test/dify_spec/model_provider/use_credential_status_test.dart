// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-credential-status.spec.tsx
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

ModelProvider provider(CustomConfiguration c) => ModelProvider(provider: 'p', customConfiguration: c);

void main() {
  group('useCredentialStatus', () {
    test('computes authorized and authRemoved status correctly', () {
      // Authorized case
      final auth = CredentialStatus.of(
        provider(
          const CustomConfiguration(
            currentCredentialId: '123',
            currentCredentialName: 'Key',
            availableCredentials: [Credential(credentialId: '123', credentialName: 'Key')],
          ),
        ),
      );
      expect(auth.authorized, isTrue);
      expect(auth.authRemoved, isFalse);

      // AuthRemoved case (found but not selected)
      final removed = CredentialStatus.of(
        provider(
          const CustomConfiguration(
            currentCredentialId: '',
            currentCredentialName: '',
            availableCredentials: [Credential(credentialId: '123')],
          ),
        ),
      );
      expect(removed.authRemoved, isTrue);
      expect(removed.authorized, isFalse);
    });

    test('handles empty or restricted credentials', () {
      // Empty case
      final empty = CredentialStatus.of(provider(const CustomConfiguration(availableCredentials: [])));
      expect(empty.hasCredential, isFalse);

      // Restricted case
      final restricted = CredentialStatus.of(
        provider(
          const CustomConfiguration(
            currentCredentialId: '123',
            availableCredentials: [Credential(credentialId: '123', notAllowedToUse: true)],
          ),
        ),
      );
      expect(restricted.notAllowedToUse, isTrue);
    });

    test('uses the summary credential usability flag', () {
      final status = CredentialStatus.of(
        provider(
          const CustomConfiguration(
            currentCredentialId: '123',
            currentCredentialName: 'Key',
            currentCredentialUsable: false,
            availableCredentials: [Credential(credentialId: '123', credentialName: 'Key')],
          ),
        ),
      );
      expect(status.hasCredential, isTrue);
      expect(status.authorized, isFalse);
      expect(status.notAllowedToUse, isTrue);
    });

    test('handles undefined custom configuration gracefully', () {
      final status = CredentialStatus.of(provider(const CustomConfiguration()));
      expect(status.hasCredential, isFalse);
      expect(status.availableCredentials, isNull);
    });

    test('handles undefined provider gracefully', () {
      final status = CredentialStatus.of(null);
      expect(status.hasCredential, isFalse);
      expect(status.authorized, isFalse);
      expect(status.authRemoved, isFalse);
      expect(status.availableCredentials, isNull);
      expect(status.currentCredentialId, isNull);
      expect(status.currentCredentialName, isNull);
    });
  });
}
