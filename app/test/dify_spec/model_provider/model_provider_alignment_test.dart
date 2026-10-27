import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_list.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/model_fakes.dart';
import '_settings_harness.dart';

final _catalog = jsonDecode(File('test/fixtures/model_provider_forms.json').readAsStringSync()) as Map;
final _providers = [for (final p in _catalog['providers'] as List) Map<String, Object?>.from(p as Map)];

void main() {
  test('all ten pinned provider forms retain every original field and option', () {
    expect(_providers, hasLength(10));
    for (final p in _providers) {
      for (final predefined in [true, false]) {
        final kind = predefined ? 'provider_credential_schema' : 'model_credential_schema';
        final raw = ((p[kind] as Map?)?['credential_form_schemas'] as List?) ?? const [];
        final result = modelFormSchemas(p, providerFormSchemaPredefined: predefined);
        final fields = result.formSchemas.where((f) => f.name != '__authorization_name__').toList();
        expect(fields.map((f) => f.name), raw.map((r) => (r as Map)['variable']), reason: '${p['provider']} $kind');
        for (var i = 0; i < fields.length; i++) {
          expect(
            (fields[i].options ?? const <FormOption>[]).map((o) => o.value),
            ((raw[i] as Map)['options'] as List).map((o) => (o as Map)['value']),
          );
        }
      }
    }
  });

  for (final p in _providers.where((p) => (p['configurate_methods'] as List).contains('customizable-model'))) {
    testWidgets('${p['provider']} shows LLM fields immediately when adding a custom model', (t) async {
      final api = RecordingModelsApi();
      await renderSettings(
        t,
        ModelModal(
          provider: p,
          configurateMethod: ConfigurationMethodEnum.customizableModel,
          mode: ModelModalModeEnum.configCustomModel,
          onCancel: () {},
          onSave: (_) {},
        ),
        env: envOf(api),
      );
      final raw = ((p['model_credential_schema'] as Map)['credential_form_schemas'] as List).cast<Map>();
      final forms = modelFormSchemas(p, providerFormSchemaPredefined: false);
      expect(forms.modelNameAndTypeFormValues['__model_type'], 'llm');
      for (final field in raw) {
        final conditions = (field['show_on'] as List?) ?? const [];
        if (conditions.isNotEmpty &&
            conditions.every((c) => (c as Map)['variable'] == '__model_type' && c['value'] == 'llm')) {
          expect(
            find.byKey(ValueKey('form-field-${field['variable']}')),
            findsOneWidget,
            reason: '${p['provider']} ${field['variable']}',
          );
        }
      }
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('editing a fixed custom model loads its credentials and keeps its LLM capability controls', (t) async {
    final p = _providers.firstWhere((p) => p['provider'] == 'langgenius/openai_api_compatible/openai_api_compatible');
    final api = RecordingModelsApi()
      ..modelCredentialData = {
        'credentials': {
          'api_key': 'masked-existing-key',
          'endpoint_url': 'https://example.com/v1',
          'mode': 'chat',
          'api_type': 'responses',
          'context_size': '1050000',
          'max_tokens_to_sample': '128000',
          'vision_support': 'support',
          'function_calling_type': 'tool_call',
        },
      };
    await renderSettings(
      t,
      ModelModal(
        provider: p,
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configModelCredential,
        fixedFields: (modelName: 'codex/gpt-6.1-terra', modelType: 'llm'),
        credential: const Credential(credentialId: 'fixture-credential'),
        isModelCredential: true,
        onCancel: () {},
        onSave: (_) {},
      ),
      env: envOf(api),
    );
    final request = api.callsOf('modelCredentials').single;
    expect(request['model'], 'codex/gpt-6.1-terra');
    expect(request['modelType'], 'llm');
    for (final name in [
      'context_size',
      'max_tokens_to_sample',
      'vision_support',
      'function_calling_type',
      'api_type',
    ]) {
      expect(find.byKey(ValueKey('form-field-$name')), findsOneWidget);
    }
    final state = t.state<BaseFormState>(find.byType(BaseForm).last);
    expect(state.form.value('context_size'), '1050000');
    state.form.setFieldValue('context_size', '262144');
    final result = state.getFormValues(needTransformWhenSecretFieldIsPristine: true);
    expect(result.isCheckValidated, isTrue);
    expect(result.values['context_size'], '262144');
    expect(result.values['vision_support'], 'support');
    expect(result.values['api_key'], '[__HIDDEN__]');
    await tapButton(t, 'common.operation.save');
    final saved = api.callsOf('updateModelCredential').single;
    expect(saved['model'], 'codex/gpt-6.1-terra');
    expect((saved['credentials'] as Map)['context_size'], '262144');
    expect((saved['credentials'] as Map)['api_key'], '[__HIDDEN__]');
  });

  testWidgets('an unknown model remains visible without a fabricated context badge', (t) async {
    final model = ModelItem.fromJson({
      'model': 'custom-alias',
      'label': {'en_US': 'custom-alias'},
      'model_type': 'llm',
      'status': 'no-configure',
      'fetch_from': 'customizable-model',
      'model_properties': <String, Object?>{},
      'schema_status': 'unknown',
      'schema_error': 'model_schema_unavailable',
    });
    await renderSettings(
      t,
      ModelListItem(provider: _providers.first, model: model, isConfigurable: true),
      env: envOf(RecordingModelsApi()),
    );
    expect(find.text('custom-alias'), findsOneWidget);
    expect(find.text('common.modelProvider.metadataUnknown'), findsOneWidget);
    expect(find.textContaining('4K'), findsNothing);
  });
}
