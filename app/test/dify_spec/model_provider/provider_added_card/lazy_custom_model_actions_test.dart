// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/lazy-custom-model-actions.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider(bool hasCustomModels) => {
  'provider': 'langgenius/openai/openai',
  'custom_configuration': {'has_custom_models': hasCustomModels},
};

late RecordingModelsApi api;

Future<void> render(WidgetTester t, Json provider) {
  api = RecordingModelsApi()
    ..providersData = [
      {
        'provider': 'langgenius/openai/openai',
        'custom_configuration': {
          'custom_models': [
            {'model': 'custom-gpt'},
          ],
          'can_added_models': [
            {'model': 'custom-gpt-2', 'model_type': 'llm'},
          ],
        },
      },
    ];
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 400),
        child: LazyCustomModelActions(provider: provider),
      ),
    ),
    env: envOf(api),
  );
}

void main() {
  group('LazyCustomModelActions', () {
    testWidgets('loads provider detail and opens credential management on demand', (t) async {
      await render(t, createProvider(true));
      expect(api.callsOf('providers'), isEmpty);
      await t.tap(find.text('common.modelProvider.auth.manageCredentials'));
      await settle(t);
      expect(t.widget<ManageCustomModelCredentials>(find.byType(ManageCustomModelCredentials)).isOpen, isTrue);
      expect(api.callsOf('providers'), hasLength(1));
    });

    testWidgets('does not render credential management without custom models', (t) async {
      await render(t, createProvider(false));
      expect(find.text('common.modelProvider.auth.manageCredentials'), findsNothing);
      expect(find.text('common.modelProvider.addModel'), findsOneWidget);
    });
  });
}
