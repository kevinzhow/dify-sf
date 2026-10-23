// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/__tests__/add-custom-model.spec.tsx
import 'package:dify_sf_app/src/cards/model_chip.dart' show ModelIcon;
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json provider({List<Json> canAdded = const [], bool allowCustomToken = true}) => {
  'provider': 'openai',
  'allow_custom_token': allowCustomToken,
  'supported_model_types': ['llm'],
  'custom_configuration': {'status': 'active', 'can_added_models': canAdded},
};

Future<void> render(WidgetTester t, Json p, {List<String> permissionKeys = managerPermissionKeys}) => renderSettings(
  t,
  Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.only(left: 500, top: 20),
      child: AddCustomModel(provider: p, configurationMethod: ConfigurationMethodEnum.predefinedModel),
    ),
  ),
  env: envOf(RecordingModelsApi(), permissionKeys: permissionKeys),
);

Finder get trigger => find.byKey(const ValueKey('add-model-button'));

void main() {
  group('AddCustomModel', () {
    testWidgets('should render the add model button', (t) async {
      await render(t, provider());
      expect(find.text('common.modelProvider.addModel'), findsOneWidget);
    });

    testWidgets('should call handleOpenModal directly when no models available and allowed', (t) async {
      await render(t, provider());
      await t.tap(trigger);
      await settle(t);
      expect(t.widget<ModelModal>(find.byType(ModelModal)).mode, ModelModalModeEnum.configCustomModel);
    });

    testWidgets('should show models list when models are available', (t) async {
      await render(
        t,
        provider(
          canAdded: const [
            {'model': 'gpt-4', 'model_type': 'llm'},
          ],
        ),
      );
      await t.tap(trigger);
      await settle(t);
      expect(find.text('gpt-4'), findsOneWidget);
      expect(find.byType(ModelIcon), findsOneWidget);
    });

    testWidgets('should call handleOpenModalForAddCustomModelToModelList when clicking a model', (t) async {
      await render(
        t,
        provider(
          canAdded: const [
            {'model': 'gpt-4', 'model_type': 'llm'},
          ],
        ),
      );
      await t.tap(trigger);
      await settle(t);
      await t.tap(find.text('gpt-4'));
      await settle(t);
      final modal = t.widget<ModelModal>(find.byType(ModelModal));
      expect(modal.mode, ModelModalModeEnum.addCustomModelToModelList);
      expect(modal.credential, isNull);
      expect(modal.model, (model: 'gpt-4', modelType: 'llm'));
    });

    testWidgets('should show existing model rows as disabled for create-only users', (t) async {
      await render(
        t,
        provider(
          canAdded: const [
            {'model': 'gpt-4', 'model_type': 'llm'},
          ],
        ),
        permissionKeys: const ['credential.create'],
      );
      await t.tap(trigger);
      await settle(t);
      expect(isEnabled('gpt-4'), isFalse);
      await t.tap(find.text('gpt-4'), warnIfMissed: false);
      await settle(t);
      expect(find.byType(ModelModal), findsNothing);
      await t.tap(find.text('common.modelProvider.auth.addNewModel'));
      await settle(t);
      expect(t.widget<ModelModal>(find.byType(ModelModal)).mode, ModelModalModeEnum.configCustomModel);
    });

    testWidgets('should call handleOpenModalForAddNewCustomModel when clicking "Add New Model" in list', (t) async {
      await render(
        t,
        provider(
          canAdded: const [
            {'model': 'gpt-4', 'model_type': 'llm'},
          ],
        ),
      );
      await t.tap(trigger);
      await settle(t);
      await t.tap(find.text('common.modelProvider.auth.addNewModel'));
      await settle(t);
      expect(t.widget<ModelModal>(find.byType(ModelModal)).mode, ModelModalModeEnum.configCustomModel);
    });

    testWidgets('should show tooltip when no models and custom tokens not allowed', (t) async {
      await render(t, provider(allowCustomToken: false));
      await hover(t, trigger);
      await settle(t);
      expect(find.text('plugin.auth.credentialUnavailable'), findsOneWidget);
      await t.tap(trigger);
      await settle(t);
      expect(find.byType(ModelModal), findsNothing);
    });
  });
}
