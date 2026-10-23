// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/model-list.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_list.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

final mockModels = [
  ModelItem.fromJson(modelJson('gpt-4', fetchFrom: 'system')),
  ModelItem.fromJson(modelJson('gpt-3.5', fetchFrom: 'system')),
];

Json provider(List<String> methods, {List<Json> customModels = const []}) => {
  'provider': 'test-provider',
  'configurate_methods': methods,
  'custom_configuration': {'custom_models': customModels},
};

var collapses = 0;

Future<void> render(
  WidgetTester t,
  Json p, {
  List<String> permissionKeys = const ['plugin.model_config', 'credential.manage', 'credential.use'],
}) {
  collapses = 0;
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 1200,
        child: ModelList(provider: p, models: mockModels, onCollapse: () => collapses++, onChange: (_) {}),
      ),
    ),
    env: envOf(RecordingModelsApi(), permissionKeys: permissionKeys),
  );
}

Finder get addModel => find.text('common.modelProvider.addModel');
Finder get manageCredentials => find.text('common.modelProvider.auth.manageCredentials');

void main() {
  group('ModelList', () {
    testWidgets('should render model count and model items', (t) async {
      await render(t, provider(const ['customizable-model']));
      expect(find.textContaining('common.modelProvider.modelsNum'), findsOneWidget);
      expect(find.text('gpt-4'), findsOneWidget);
      expect(find.text('gpt-3.5'), findsOneWidget);
    });

    testWidgets('should trigger collapse when collapsed label is clicked', (t) async {
      await render(t, provider(const ['customizable-model']));
      await t.tap(find.textContaining('common.modelProvider.modelsNum'));
      expect(collapses, 1);
    });

    testWidgets('should hide custom model actions without plugin.model_config', (t) async {
      await render(t, provider(const ['customizable-model']), permissionKeys: const []);
      expect(manageCredentials, findsNothing);
      expect(addModel, findsNothing);
    });

    testWidgets('should hide custom model actions when provider uses predefinedModel only', (t) async {
      await render(t, provider(const ['predefined-model']));
      expect(manageCredentials, findsNothing);
      expect(addModel, findsNothing);
    });

    testWidgets('should hide custom model actions when provider uses fetchFromRemote only', (t) async {
      await render(t, provider(const ['fetch-from-remote']));
      expect(manageCredentials, findsNothing);
      expect(addModel, findsNothing);
    });

    testWidgets('should show Add Model but hide Manage Credentials for configurable providers', (t) async {
      await render(t, provider(const ['customizable-model']), permissionKeys: const ['plugin.model_config']);
      expect(manageCredentials, findsNothing);
      expect(addModel, findsOneWidget);
    });

    testWidgets('should hide custom model actions when provider is configurable but user cannot configure models', (
      t,
    ) async {
      await render(t, provider(const ['customizable-model']), permissionKeys: const []);
      expect(manageCredentials, findsNothing);
      expect(addModel, findsNothing);
    });
  });
}
