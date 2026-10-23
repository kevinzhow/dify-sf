// dify-spec: web/app/components/header/account-setting/model-provider-page/model-modal/__tests__/dialog.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider({Object? help = const {}}) => {
  'provider': 'openai',
  'label': {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  'help': help == const {}
      ? {
          'title': {'en_US': 'Help', 'zh_Hans': '帮助'},
          'url': {'en_US': 'https://example.com', 'zh_Hans': 'https://example.cn'},
        }
      : help,
  'supported_model_types': <Object?>[],
  'configurate_methods': <Object?>[],
  'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
  'model_credential_schema': {'credential_form_schemas': <Object?>[]},
  'custom_configuration': {'status': 'active'},
  'allow_custom_token': true,
};

Future<void> render(
  WidgetTester t,
  Json provider, {
  String language = 'en_US',
  ModelModalModeEnum mode = ModelModalModeEnum.configProviderCredential,
  RecordingModelsApi? api,
}) {
  final a = api ?? RecordingModelsApi();
  return renderSettings(
    t,
    ModelModal(
      key: UniqueKey(),
      provider: provider,
      configurateMethod: ConfigurationMethodEnum.predefinedModel,
      mode: mode,
      onCancel: () {},
      onSave: (_) {},
    ),
    env: envOf(
      a,
      permissionKeys: const [],
      models: WorkspaceModels(a, fixedLanguage: language),
    ),
  );
}

SemanticsData? helpLink() {
  final f = find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isLink);
  return f.evaluate().isEmpty ? null : f.evaluate().single.getSemanticsData();
}

void main() {
  group('ModelModal dialog branches', () {
    testWidgets('should pass an empty credential list to the selector when no credentials are available', (t) async {
      await render(t, createProvider(), mode: ModelModalModeEnum.addCustomModelToModelList);
      expect(t.widget<CredentialSelector>(find.byType(CredentialSelector)).credentials, isEmpty);
    });

    testWidgets('should hide the help link when provider help is missing', (t) async {
      await render(t, createProvider(help: null));
      expect(find.byKey(const ValueKey('model-modal-help')), findsNothing);
    });

    testWidgets('should prevent navigation when help text exists without a help url', (t) async {
      await render(
        t,
        createProvider(
          help: {
            'title': {'en_US': 'English Help'},
            'url': '',
          },
        ),
        language: 'zh_Hans',
      );
      expect(find.byKey(const ValueKey('model-modal-help')), findsOneWidget);
      expect(find.textContaining('English Help', findRichText: true), findsOneWidget);
      // Not a link: there is nowhere to go.
      expect(helpLink(), isNull);
    });

    testWidgets('should fall back to localized and english help urls when titles are missing', (t) async {
      await render(
        t,
        createProvider(
          help: {
            'url': {'zh_Hans': 'https://example.cn', 'en_US': 'https://example.com'},
          },
        ),
        language: 'zh_Hans',
      );
      expect(helpLink()?.label, 'https://example.cn');
      expect(helpLink()?.linkUrl, Uri.parse('https://example.cn'));

      await render(
        t,
        createProvider(
          help: {
            'url': {'en_US': 'https://example.com'},
          },
        ),
        language: 'zh_Hans',
      );
      expect(helpLink()?.label, 'https://example.com');
      expect(helpLink()?.linkUrl, Uri.parse('https://example.com'));
    });
  });
}
