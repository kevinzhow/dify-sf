import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export '../../../dify_test_i18n.dart';

/// Dify's spec fixture `makeModelItem`.
ModelItem makeModelItem({
  String model = 'gpt-4',
  I18nText label = const {'en_US': 'GPT-4', 'zh_Hans': 'GPT-4'},
  List<String>? features,
  String status = ModelStatusEnum.active,
  Map<String, Object?> modelProperties = const {},
  bool deprecated = false,
}) => ModelItem(
  model: model,
  label: label,
  features: features,
  status: status,
  modelProperties: modelProperties,
  deprecated: deprecated,
);

/// Dify's spec fixture `makeModel` (a provider with its models).
ProviderWithModels makeModel({
  String provider = 'openai',
  I18nText label = const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  List<ModelItem>? models,
}) => ProviderWithModels(provider: provider, label: label, models: models ?? [makeModelItem()]);

/// The summary entry (installed provider) of [model]; with [credentialName], an API key that is [usable].
ModelProvider summaryOf(
  ProviderWithModels model, {
  String? credentialName,
  bool usable = true,
  String preferredProviderType = PreferredProviderTypeEnum.custom,
  bool systemConfigurationEnabled = false,
}) => ModelProvider(
  provider: model.provider,
  label: model.label,
  preferredProviderType: preferredProviderType,
  systemConfigurationEnabled: systemConfigurationEnabled,
  customConfiguration: credentialName == null
      ? const CustomConfiguration()
      : CustomConfiguration(
          status: 'active',
          currentCredentialId: 'c1',
          currentCredentialName: credentialName,
          availableCredentials: [Credential(credentialId: 'c1', credentialName: credentialName)],
          currentCredentialUsable: usable,
        ),
);

/// A workspace with [models] as its text generation models, every provider installed.
ModelCatalog catalogOf(List<ProviderWithModels> models, {List<ModelProvider>? providers, String language = 'en_US'}) =>
    ModelCatalog(
      providers: providers ?? [for (final m in models) summaryOf(m)],
      modelLists: {ModelTypeEnum.textGeneration: models},
      language: language,
    );

/// [child] in an app with [services] in scope, 1200 x 900.
Future<void> pumpHost(WidgetTester t, Widget child, {LlmGroupServices services = LlmGroupServices.empty}) async {
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: LlmGroupScope(
          services: services,
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: SizedBox(width: 360, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(t);
}

/// A few frames (the loading spinner never settles).
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The control whose accessible name is [label] (Dify's `getByRole('button', { name })`).
Finder named(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// Whether [label]'s control is disabled.
bool isDisabled(WidgetTester t, String label) => t.widget<DifyPressable>(named(label)).disabled;
