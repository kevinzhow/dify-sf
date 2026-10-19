// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/model-auth-dropdown/__tests__/dialog.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const state = CredentialPanelState(
  variant: CardVariant.apiActive,
  priority: UsagePriority.apiKey,
  supportsCredits: true,
  showPrioritySwitcher: false,
  hasCredentials: false,
  isCreditsExhausted: false,
);

void main() {
  group('DropdownContent dialog branches', () {
    testWidgets('should fall back to an empty credential list when the provider has no credentials', (t) async {
      await renderSettings(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: DropdownContent(
            provider: const {
              'provider': 'test',
              'custom_configuration': {'available_credentials': null},
              'configurate_methods': <Object?>[],
              'supported_model_types': <Object?>[],
            },
            state: state,
            onClose: () {},
          ),
        ),
        env: envOf(RecordingModelsApi(), permissionKeys: const []),
      );
      expect(t.widget<ApiKeySection>(find.byType(ApiKeySection)).credentials, isEmpty);
    });
  });
}
