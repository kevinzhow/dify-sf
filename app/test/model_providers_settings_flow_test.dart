/// The model provider settings end to end over collab_client's in-memory server (FakeModelProvidersApi: the server's
/// rules over a fixture of the vendored definitions): adding an API key (validated on save), a refused key, editing a
/// key without retyping the secret (the `[__HIDDEN__]` round trip), a custom Ollama model, and a member who only views.
library;

import 'package:collab_client/collab_client.dart' show AccountRole;
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/settings/integrations_page.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart' show ModelModalModeEnum;
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/model_provider/_settings_harness.dart';

const _openai = 'langgenius/openai/openai';

late FakeModelProvidersApi api;
late WorkspaceModels models;
final validated = <Map<String, Object?>>[];

Future<void> _open(WidgetTester t, {String role = AccountRole.owner}) async {
  validated.clear();
  api = FakeModelProvidersApi(
    validator: (provider, credentials) {
      validated.add(credentials);
      return credentials.values.any((v) => v is String && v.startsWith('bad')) ? 'Incorrect API key provided' : null;
    },
  );
  models = WorkspaceModels(api, fixedLanguage: 'en_US');
  await renderSettings(
    t,
    const SizedBox(width: 1440, height: 900, child: IntegrationsPage()),
    env: ModelProviderEnv.forRole(models, role),
  );
}

Finder _card(String provider) =>
    find.byWidgetPredicate((w) => w is ProviderAddedCard && w.provider['provider'] == provider);
Finder _in(String provider, Finder f) => find.descendant(of: _card(provider), matching: f);
Finder _field(String name) =>
    find.descendant(of: find.byKey(ValueKey('form-input-$name')), matching: find.byType(EditableText));

Future<void> _openOpenAIKeyModal(WidgetTester t) async {
  await t.tap(_in(_openai, find.byKey(const ValueKey('model-auth-dropdown-trigger'))));
  await settle(t);
  await t.tap(find.byKey(const ValueKey('api-key-section-add')));
  await settle(t);
}

void main() {
  testWidgets('adds an OpenAI API key: validated on save, the provider becomes configured with its models', (t) async {
    await _open(t);
    expect(find.text('common.modelProvider.toBeConfigured'), findsOneWidget);
    await _openOpenAIKeyModal(t);
    await t.enterText(_field('openai_api_key'), 'sk-good-key-123456');
    await t.tap(find.byKey(const ValueKey('model-modal-save')));
    await settle(t);
    expect(find.byType(ModelModal), findsNothing);
    expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
    expect(validated.last['openai_api_key'], 'sk-good-key-123456');
    // The card now shows the key and lists its models (expanded after a new credential).
    expect(_in(_openai, find.text('API KEY 1')), findsOneWidget);
    expect(models.modelList('llm').map((p) => p.provider), contains(_openai));
  });

  testWidgets('a refused key toasts the provider\'s message and keeps the modal open', (t) async {
    await _open(t);
    await _openOpenAIKeyModal(t);
    await t.enterText(_field('openai_api_key'), 'bad-key-123456');
    await t.tap(find.byKey(const ValueKey('model-modal-save')));
    await settle(t);
    expect(find.byType(ModelModal), findsOneWidget);
    expect(find.textContaining('Incorrect API key provided'), findsOneWidget);
    expect(_in(_openai, find.text('API KEY 1')), findsNothing);
  });

  testWidgets('editing a key without retyping it sends [__HIDDEN__]: the server keeps the stored secret', (t) async {
    await _open(t);
    await api.createProviderCredential(_openai, credentials: {'openai_api_key': 'sk-good-key-123456'}, name: 'Main');
    await models.refreshSummary();
    await settle(t);
    await t.tap(_in(_openai, find.byKey(const ValueKey('model-auth-dropdown-trigger'))));
    await settle(t);
    await hover(t, find.text('Main').last);
    await t.tap(
      find.byWidgetPredicate(
        (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('credential-edit-'),
      ),
    );
    await settle(t);
    // The secret shows masked; the name is editable.
    final shown = t.widget<EditableText>(_field('openai_api_key')).controller.text;
    expect(shown, isNot('sk-good-key-123456'));
    expect(shown, contains('*'));
    await t.enterText(_field('__authorization_name__'), 'Renamed');
    validated.clear();
    await t.tap(find.byKey(const ValueKey('model-modal-save')));
    await settle(t);
    expect(find.byType(ModelModal), findsNothing);
    // Validated with the stored secret, not the mask.
    expect(validated.single['openai_api_key'], 'sk-good-key-123456');
    expect(_in(_openai, find.text('Renamed')), findsOneWidget);
  });

  testWidgets('adds a custom Ollama model with its credential', (t) async {
    await _open(t);
    await t.tap(_in('langgenius/ollama/ollama', find.byKey(const ValueKey('add-model-button'))));
    await settle(t);
    expect(t.widget<ModelModal>(find.byType(ModelModal)).mode, ModelModalModeEnum.configCustomModel);
    await t.enterText(_field('__model_name'), 'llama3');
    await t.tap(find.byKey(const ValueKey('form-select-__model_type')));
    await settle(t);
    await t.tap(find.text('LLM').last);
    await settle(t);
    await t.enterText(_field('base_url'), 'http://localhost:11434');
    await t.tap(find.byKey(const ValueKey('model-modal-save')));
    await settle(t);
    expect(find.byType(ModelModal), findsNothing);
    expect(models.modelList('llm').expand((p) => p.models).map((m) => m.model), contains('llama3'));
  });

  testWidgets('a normal member sees the provider cards without credentials, model lists or default models', (t) async {
    await _open(t, role: AccountRole.normal);
    expect(_card(_openai), findsOneWidget);
    expect(find.byType(CredentialPanel), findsNothing);
    expect(find.byKey(const ValueKey('provider-show-models')), findsNothing);
    expect(find.byKey(const ValueKey('system-model-selector-button')), findsNothing);
    expect(find.byKey(const ValueKey('add-model-button')), findsNothing);
  });

  testWidgets('custom model settings support switching, removal and re-adding with credentials retained', (t) async {
    const ollama = 'langgenius/ollama/ollama';
    const name = 'journey-model';
    await _open(t);
    for (final label in ['Primary', 'Backup']) {
      await api.createModelCredential(
        ollama,
        model: name,
        modelType: 'llm',
        credentials: {
          'base_url': 'http://fixture.invalid:11434',
          'mode': 'chat',
          'context_size': '4096',
          'max_tokens': '4096',
        },
        name: label,
      );
    }
    await models.refreshSummary();
    await settle(t);
    await t.ensureVisible(_in(ollama, find.byKey(const ValueKey('provider-show-models'))));
    await t.tap(_in(ollama, find.byKey(const ValueKey('provider-show-models'))));
    await settle(t);
    final configure = find.byKey(const ValueKey('model-configure-journey-model'));
    await t.ensureVisible(configure);
    await t.tap(configure);
    await settle(t);
    await t.tap(find.text('Backup'));
    await settle(t);
    var saved = await api.modelCredentials(ollama, model: name, modelType: 'llm');
    expect(saved['current_credential_name'], 'Backup');
    final before = saved['available_credentials'] as List;

    final remove = find.byKey(const ValueKey('model-remove-journey-model'));
    await t.ensureVisible(remove);
    await t.tap(remove);
    await settle(t);
    await t.tap(find.byKey(const ValueKey('alert-confirm')));
    await settle(t);
    expect(find.byKey(const ValueKey('model-remove-journey-model')), findsNothing);
    saved = await api.modelCredentials(ollama, model: name, modelType: 'llm');
    expect(saved['available_credentials'], before);

    await t.ensureVisible(_in(ollama, find.byKey(const ValueKey('add-model-button'))));
    await t.tap(_in(ollama, find.byKey(const ValueKey('add-model-button'))));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('can-added-model-journey-model')));
    await settle(t);
    expect(t.widget<ModelModal>(find.byType(ModelModal)).mode, ModelModalModeEnum.addCustomModelToModelList);
    await t.tap(find.byKey(const ValueKey('credential-selector-trigger')));
    await settle(t);
    await t.tap(find.text('Backup').last);
    await settle(t);
    await t.tap(find.byKey(const ValueKey('model-modal-save')));
    await settle(t);
    expect((await api.providerModels(ollama)).any((m) => m['model'] == name), isTrue);
    expect(find.byKey(const ValueKey('model-remove-journey-model')), findsOneWidget);
    expect(api.requests['removeCustomModel'], 1);
    expect(api.requests['deleteModelCredential'] ?? 0, 0);
  });
}
