import 'dart:convert';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify's test i18n (`<ns>.<key>`, then `:<params as JSON>`), with Dify's camel-case namespace names for the asset
/// files' kebab-case ones (`app-debug` is `appDebug`).
class KbTestTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) {
    final id = ns.replaceAllMapped(RegExp(r'-(\w)'), (m) => m[1]!.toUpperCase());
    return params.isEmpty ? '$id.$key' : '$id.$key:${jsonEncode(params)}';
  }
}

void useKbTestTranslator() => DifyI18n.current = KbTestTranslator();

/// [child] in an app, 400 px wide, below a [KnowledgeBaseHost] with [catalog] (and the docs at docs.example.com).
Widget kbApp(
  Widget child, {
  ModelCatalog catalog = ModelCatalog.empty,
  List<ModelItem>? Function(String provider)? providerModels,
  ValueNotifier<bool>? dismissed,
}) => MaterialApp(
  home: Material(
    child: KnowledgeBaseHost(
      catalog: catalog,
      providerModels: providerModels,
      multimodalTipDismissed: dismissed ?? ValueNotifier(false),
      docLink: (path) => 'https://docs.example.com$path',
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, child: SingleChildScrollView(child: child)),
      ),
    ),
  ),
);

/// Text showing [s] (also upper-cased, as `uppercase` utilities render it).
Finder textOf(String s) => find.byWidgetPredicate(
  (w) => w is Text && (w.data == s || w.data == s.toUpperCase()),
  description: 'text "$s"',
);

/// `createModelItem` (workflow/__tests__/model-provider-fixtures.ts).
Map<String, Object?> createModelItemJson([Map<String, Object?> overrides = const {}]) => {
  'model': 'text-embedding-3-large',
  'label': {'en_US': 'Text Embedding 3 Large', 'zh_Hans': 'Text Embedding 3 Large'},
  'model_type': ModelTypeEnum.textEmbedding,
  'fetch_from': 'predefined-model',
  'status': ModelStatusEnum.active,
  'model_properties': <String, Object?>{},
  'load_balancing_enabled': false,
  ...overrides,
};

ModelItem createModelItem([Map<String, Object?> overrides = const {}]) =>
    ModelItem.fromJson(createModelItemJson(overrides));

/// `createModel`.
Map<String, Object?> createModelJson([Map<String, Object?> overrides = const {}]) => {
  'tenant_id': 'test-workspace',
  'provider': 'openai',
  'icon_small': {'en_US': 'icon', 'zh_Hans': 'icon'},
  'icon_small_dark': {'en_US': 'icon-dark', 'zh_Hans': 'icon-dark'},
  'label': {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  'models': [createModelItemJson()],
  'status': ModelStatusEnum.active,
  ...overrides,
};

ProviderWithModels createModel([Map<String, Object?> overrides = const {}]) =>
    ProviderWithModels.fromJson(createModelJson(overrides));

/// `createCredentialState`.
CredentialPanelState createCredentialState() => const CredentialPanelState(
  variant: CardVariant.apiActive,
  priority: UsagePriority.apiKeyOnly,
  supportsCredits: false,
  showPrioritySwitcher: false,
  hasCredentials: true,
  isCreditsExhausted: false,
);
