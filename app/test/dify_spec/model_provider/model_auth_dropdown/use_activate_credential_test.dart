// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/model-auth-dropdown/__tests__/use-activate-credential.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

final provider = <String, Object?>{
  'provider': 'langgenius/openai/openai',
  'supported_model_types': ['llm', 'text-embedding'],
  'custom_configuration': {
    'current_credential_id': 'cred-1',
    'available_credentials': [
      {'credential_id': 'cred-1', 'credential_name': 'Primary'},
      {'credential_id': 'cred-2', 'credential_name': 'Backup'},
    ],
  },
};

late RecordingModelsApi api;

Future<ActivateCredential> render(WidgetTester t) async {
  api = RecordingModelsApi();
  await renderSettings(t, const SizedBox(), env: envOf(api));
  return ActivateCredential();
}

void main() {
  group('useActivateCredential', () {
    testWidgets('should expose the current credential id by default', (t) async {
      final a = await render(t);
      expect(a.selectedCredentialId(provider), 'cred-1');
      expect(a.isActivating, isFalse);
    });

    testWidgets('should expose the pending mutation state', (t) async {
      final a = await render(t);
      final gate = api.hold['switchProviderCredential'] = Completer();
      final f = a.activate(envOf(api), provider, const Credential(credentialId: 'cred-2', credentialName: 'Backup'));
      expect(a.isActivating, isTrue);
      gate.complete();
      await f;
      expect(a.isActivating, isFalse);
    });

    testWidgets('should skip mutation when the selected credential is already active', (t) async {
      final a = await render(t);
      await a.activate(envOf(api), provider, const Credential(credentialId: 'cred-1', credentialName: 'Backup'));
      expect(api.callsOf('switchProviderCredential'), isEmpty);
      expect(a.selectedCredentialId(provider), 'cred-1');
    });

    testWidgets('should optimistically select the credential and refresh provider data on success', (t) async {
      final a = await render(t);
      final gate = api.hold['switchProviderCredential'] = Completer();
      final f = a.activate(envOf(api), provider, const Credential(credentialId: 'cred-2', credentialName: 'Backup'));
      expect(a.selectedCredentialId(provider), 'cred-2');
      expect(api.callsOf('switchProviderCredential'), [
        {'provider': 'langgenius/openai/openai', 'credentialId': 'cred-2'},
      ]);
      gate.complete();
      await f;
      await settle(t);
      expect(find.text('common.api.actionSuccess'), findsOneWidget);
      expect(api.callsOf('summaries'), hasLength(1));
      expect([for (final c in api.callsOf('modelsOfType')) c['modelType']], ['llm', 'text-embedding']);
    });

    testWidgets('should reset the optimistic selection and show an error toast when activation fails', (t) async {
      final a = await render(t);
      api.fail['switchProviderCredential'] = Exception('failed');
      final gate = api.hold['switchProviderCredential'] = Completer();
      final f = a.activate(envOf(api), provider, const Credential(credentialId: 'cred-2', credentialName: 'Backup'));
      expect(a.selectedCredentialId(provider), 'cred-2');
      gate.complete();
      await f;
      await settle(t);
      expect(a.selectedCredentialId(provider), 'cred-1');
      expect(find.text('common.actionMsg.modifiedUnsuccessfully'), findsOneWidget);
    });
  });
}
