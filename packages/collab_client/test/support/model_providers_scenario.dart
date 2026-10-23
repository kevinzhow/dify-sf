import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

const anthropic = 'langgenius/anthropic/anthropic';
const oaic = 'langgenius/openai_api_compatible/openai_api_compatible';
const openai = 'langgenius/openai/openai';

/// What the model provider calls must do, whoever answers them (the in-memory fake or a real server, protocol 1.9).
///
/// Fit for a shared server: it only changes credentials and custom models it creates (names and models carry [unique]),
/// deletes them again (restoring Anthropic's current credential), and asserts nothing about other users' settings; reading
/// the default model may store one, as any client's first read does. [stubBase] is a provider stand-in the server can
/// reach (`/v1/models`, `/oaic/models` 404, `/oaic/chat/completions`), accepting keys that start with `sk-good`; a real
/// provider is never involved. [validates]: the server checks credentials on save (a refused key is then
/// `credential_validation_failed`).
Future<void> modelProvidersScenario(
  ModelProvidersApi owner,
  ModelProvidersApi viewer, {
  required String unique,
  required String stubBase,
  required bool validates,
}) async {
  // ----- the catalog -----
  final summaries = await owner.summaries();
  final ids = [for (final s in summaries) s['provider']];
  expect(ids, containsAll([openai, oaic]));
  final summary = summaries.firstWhere((s) => s['provider'] == openai);
  expect(summary['plugin_id'], 'langgenius/openai');
  expect(summary['label'], {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'});
  expect(summary['preferred_provider_type'], 'custom');
  expect(summary['system_configuration'], {'enabled': false});
  expect((summary['custom_configuration']! as Map)['status'], anyOf('active', 'no-configure'));
  final iconPath = (summary['icon_small']! as Map)['en_US']! as String;
  expect(iconPath, '/v1/workspace/model-providers/$openai/icon_small/en_US');
  expect(owner.iconUrl(iconPath).isAbsolute, isTrue);
  final icon = await owner.icon(iconPath);
  expect(icon, isNotNull);
  expect(icon!.isSvg, isTrue);
  expect(String.fromCharCodes(icon.bytes), contains('<svg'));
  expect(await owner.icon('/v1/workspace/model-providers/$openai/icon_large/en_US'), isNull);

  final providers = await owner.providers();
  final openaiProvider = providers.firstWhere((p) => p['provider'] == openai);
  final schema = openaiProvider['provider_credential_schema']! as Map;
  final fields = [for (final f in schema['credential_form_schemas']! as List) (f as Map)['variable']];
  expect(fields, contains('openai_api_key'));
  expect(openaiProvider['model_credential_schema'], isA<Map<String, Object?>>());
  final rerank = await owner.providers(modelType: ModelProviderModelTypes.rerank);
  expect(rerank.every((p) => (p['supported_model_types']! as List).contains('rerank')), isTrue);

  final models = await owner.providerModels(openai);
  expect(models, isNotEmpty);
  expect(models.every((m) => (m['provider']! as Map)['provider'] == openai), isTrue);
  expect(models.first.keys, containsAll(['model', 'label', 'model_type', 'fetch_from', 'model_properties', 'status']));

  // Members read, only the owner and admins write.
  expect((await viewer.summaries()).length, summaries.length);
  await expectLater(
    viewer.createProviderCredential(anthropic, credentials: {'anthropic_api_key': 'sk-good-viewer'}),
    throwsA(isA<TransportException>().having((e) => e.forbidden, 'forbidden', isTrue)),
  );
  await expectLater(
    viewer.providerCredentials(openai),
    throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 403)),
  );
  await expectLater(
    owner.providerModels('nobody/x/y'),
    throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
  );
  await expectLater(
    owner.modelsOfType('poems'),
    throwsA(isA<TransportException>().having((e) => e.code, 'code', 'bad_request')),
  );

  // ----- a provider credential -----
  final name = 'conf $unique'.substring(0, ('conf $unique').length.clamp(0, 30));
  final key = 'sk-good-$unique-0123456789';
  await owner.createProviderCredential(
    anthropic,
    credentials: {'anthropic_api_key': key, 'anthropic_api_url': stubBase},
    name: name,
  );
  Future<Map<String, Object?>> cred() async {
    final p = (await owner.providers()).firstWhere((p) => p['provider'] == anthropic);
    final config = p['custom_configuration']! as Map<String, Object?>;
    return (config['available_credentials']! as List).cast<Map<String, Object?>>().firstWhere(
      (c) => c['credential_name'] == name,
    );
  }

  final id = (await cred())['credential_id']! as String;
  // On a shared server the provider may have a current credential of someone else's: it is restored at the end.
  final previous =
      ((summaries.firstWhere((s) => s['provider'] == anthropic)['custom_configuration']!
              as Map)['current_credential_id'])
          as String?;
  try {
    final masked = await owner.providerCredentials(anthropic, credentialId: id);
    expect(masked['anthropic_api_key'], '${key.substring(0, 6)}************${key.substring(key.length - 2)}');
    expect(masked['anthropic_api_url'], stubBase);
    await expectLater(
      owner.createProviderCredential(
        anthropic,
        credentials: {'anthropic_api_key': key, 'anthropic_api_url': stubBase},
        name: name,
      ),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'credential_name_exists')),
    );
    await expectLater(
      owner.createProviderCredential(anthropic, credentials: {'anthropic_api_url': stubBase}),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'bad_request')),
    );
    if (validates) {
      await expectLater(
        owner.createProviderCredential(
          anthropic,
          credentials: {'anthropic_api_key': 'bad-key-$unique', 'anthropic_api_url': stubBase},
        ),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'credential_validation_failed')),
      );
      final failed = await owner.validateProviderCredentials(
        anthropic,
        credentials: {'anthropic_api_key': 'bad-key-$unique', 'anthropic_api_url': stubBase},
      );
      expect(failed.ok, isFalse);
      expect(failed.error, isNotEmpty);
    }
    final passed = await owner.validateProviderCredentials(
      anthropic,
      credentials: {'anthropic_api_key': key, 'anthropic_api_url': stubBase},
    );
    expect(passed.ok, isTrue);
    // [__HIDDEN__] keeps the secret; the rest changes.
    await owner.updateProviderCredential(
      anthropic,
      credentialId: id,
      credentials: {'anthropic_api_key': hiddenSecret, 'anthropic_api_url': '$stubBase/'},
    );
    final after = await owner.providerCredentials(anthropic, credentialId: id);
    expect(after['anthropic_api_key'], masked['anthropic_api_key']);
    expect(after['anthropic_api_url'], '$stubBase/');
    // Make it current: the provider's models are active and have parameter rules.
    await owner.switchProviderCredential(anthropic, credentialId: id);
    final anthropicModels = await owner.providerModels(anthropic);
    expect(
      anthropicModels
          .where((m) => m['model_type'] == 'llm')
          .every((m) => m['status'] == 'active' || m['status'] == 'disabled'),
      isTrue,
    );
    final llm = await owner.modelsOfType(ModelProviderModelTypes.llm);
    expect(llm.map((p) => p['provider']), contains(anthropic));
    final firstModel =
        ((llm.firstWhere((p) => p['provider'] == anthropic)['models']! as List).first as Map)['model']! as String;
    final rules = await owner.parameterRules(anthropic, firstModel);
    expect(rules, isNotEmpty);
    expect(rules.every((r) => (r['label']! as Map)['en_US'] != null && r.containsKey('use_template')), isTrue);
    // The default model is an active model (picked and kept by the server when none was set).
    final def = await owner.defaultModel(ModelProviderModelTypes.llm);
    expect(def, isNotNull);
    expect(def!['model_type'], 'llm');
    expect((def['provider']! as Map)['models'], isEmpty);
    await expectLater(
      owner.setDefaultModels([
        const DefaultModelSetting(modelType: 'llm', provider: anthropic, model: 'no-such-model'),
      ]),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'bad_request')),
    );
    await owner.setDefaultModels([
      DefaultModelSetting(
        modelType: 'llm',
        provider: def['provider'] is Map ? (def['provider']! as Map)['provider'] as String : null,
        model: def['model'] as String?,
      ),
    ]);
  } finally {
    if (previous != null && previous != id) await owner.switchProviderCredential(anthropic, credentialId: previous);
    await owner.deleteProviderCredential(anthropic, credentialId: id);
  }
  expect(
    (((await owner.providers()).firstWhere((p) => p['provider'] == anthropic)['custom_configuration']!
                as Map)['available_credentials']!
            as List)
        .any((c) => (c as Map)['credential_id'] == id),
    isFalse,
  );

  // ----- a custom model of an OpenAI-API-compatible server -----
  final model = 'conf-$unique';
  Map<String, Object?> creds(String k) => {
    'endpoint_url': '$stubBase/oaic',
    'api_key': k,
    'mode': 'chat',
    'context_size': '32768',
    'max_tokens_to_sample': '8192',
  };
  await owner.createModelCredential(oaic, model: model, modelType: 'llm', credentials: creds('sk-good-$unique-a'));
  var read = await owner.modelCredentials(oaic, model: model, modelType: 'llm');
  final firstId = read['current_credential_id']! as String;
  try {
    expect((read['credentials']! as Map)['api_key'], startsWith('sk-goo'));
    expect((read['credentials']! as Map)['api_key'], contains('************'));
    expect(read['load_balancing'], {'enabled': false, 'configs': <Object?>[]});
    final listed = (await owner.modelsOfType('llm')).firstWhere((p) => p['provider'] == oaic)['models']! as List;
    final entry = listed.cast<Map<String, Object?>>().firstWhere((m) => m['model'] == model);
    expect(entry['fetch_from'], 'customizable-model');
    expect(entry['status'], 'active');
    expect((entry['model_properties']! as Map)['mode'], 'chat');
    final rules = await owner.parameterRules(oaic, model);
    expect([for (final r in rules) r['name']], containsAll(['temperature', 'top_p', 'max_tokens']));
    // A second credential; switch to it (Dify's "add to model list"), and back out of / into the list.
    await owner.createModelCredential(
      oaic,
      model: model,
      modelType: 'llm',
      credentials: creds('sk-good-$unique-b'),
      name: 'backup',
    );
    read = await owner.modelCredentials(oaic, model: model, modelType: 'llm');
    final secondId =
        (read['available_credentials']! as List).cast<Map<String, Object?>>().firstWhere(
              (c) => c['credential_name'] == 'backup',
            )['credential_id']!
            as String;
    await owner.switchModelCredential(oaic, model: model, modelType: 'llm', credentialId: secondId);
    expect((await owner.modelCredentials(oaic, model: model, modelType: 'llm'))['current_credential_name'], 'backup');
    await expectLater(
      owner.switchModelCredential(oaic, model: model, modelType: 'llm', credentialId: secondId),
      throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
    );
    await owner.removeCustomModel(oaic, model: model, modelType: 'llm');
    var config = (await owner.providers()).firstWhere((p) => p['provider'] == oaic)['custom_configuration']! as Map;
    expect(config['can_added_models']! as List, anyElement(equals({'model': model, 'model_type': 'llm'})));
    await owner.switchModelCredential(oaic, model: model, modelType: 'llm', credentialId: firstId);
    await owner.addCustomModel(oaic, model: model, modelType: 'llm', credentialId: secondId);
    config = (await owner.providers()).firstWhere((p) => p['provider'] == oaic)['custom_configuration']! as Map;
    final custom = (config['custom_models']! as List).cast<Map<String, Object?>>().firstWhere(
      (m) => m['model'] == model,
    );
    expect(custom['credentials'], isNull);
    expect(custom['current_credential_id'], secondId);
    expect(custom['unadded_to_model_list'], isFalse);
    // Disabling takes it out of the selector list.
    await owner.disableModel(oaic, model: model, modelType: 'llm');
    expect(
      (await owner.providerModels(oaic)).firstWhere((m) => m['model'] == model)['status'],
      'disabled',
    );
    await expectLater(
      owner.parameterRules(oaic, model),
      throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
    );
    await owner.enableModel(oaic, model: model, modelType: 'llm');
    await owner.deleteModelCredential(oaic, model: model, modelType: 'llm', credentialId: secondId);
  } finally {
    for (final c
        in ((await owner.modelCredentials(oaic, model: model, modelType: 'llm'))['available_credentials']! as List)) {
      await owner.deleteModelCredential(
        oaic,
        model: model,
        modelType: 'llm',
        credentialId: (c as Map)['credential_id']! as String,
      );
    }
  }
  final gone = (await owner.modelsOfType('llm'))
      .where((p) => p['provider'] == oaic)
      .expand((p) => p['models']! as List);
  expect(gone.any((m) => (m as Map)['model'] == model), isFalse);
}
