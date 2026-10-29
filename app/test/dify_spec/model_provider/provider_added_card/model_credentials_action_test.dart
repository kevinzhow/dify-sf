import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_credentials_action.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_list.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const provider = <String, Object?>{
  'provider': 'test-provider',
  'allow_custom_token': true,
  'supported_model_types': ['llm'],
  'model_credential_schema': {'credential_form_schemas': <Object?>[]},
  'custom_configuration': {'status': 'active'},
};

Future<RecordingModelsApi> render(WidgetTester t, {List<String> permissions = managerPermissionKeys}) async {
  final api = RecordingModelsApi()
    ..providersData = [provider]
    ..modelCredentialData = {
      'current_credential_id': 'c1',
      'available_credentials': [
        {'credential_id': 'c1', 'credential_name': 'Primary'},
        {'credential_id': 'c2', 'credential_name': 'Backup'},
      ],
    };
  await renderSettings(
    t,
    Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 160),
        child: SizedBox(
          width: 600,
          child: ModelListItem(
            provider: provider,
            model: ModelItem.fromJson(modelJson('custom-model', fetchFrom: 'customizable-model')),
            isConfigurable: true,
          ),
        ),
      ),
    ),
    env: envOf(api, permissionKeys: permissions),
  );
  return api;
}

Future<void> open(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('model-configure-custom-model')));
  await settle(t);
}

void main() {
  testWidgets('model row configuration reaches credential selection independently of load balancing', (t) async {
    final api = await render(t);
    expect(api.callsOf('providers'), isEmpty);
    await open(t);
    expect(api.callsOf('modelCredentials'), [
      {
        'provider': 'test-provider',
        'model': 'custom-model',
        'modelType': 'llm',
        'configFrom': null,
        'credentialId': null,
      },
    ]);
    await t.tap(find.text('Backup'));
    await settle(t);
    expect(api.callsOf('switchModelCredential'), [
      {'provider': 'test-provider', 'model': 'custom-model', 'modelType': 'llm', 'credentialId': 'c2'},
    ]);
    expect(api.callsOf('deleteModelCredential'), isEmpty);
  });

  testWidgets('model row keeps configuration disabled during loading and permits a failed read to retry', (t) async {
    final api = await render(t);
    final gate = Completer<void>();
    api.hold['providers'] = gate;
    await open(t);
    expect(find.text('Backup'), findsNothing);
    expect(t.widget<DifyIconButton>(find.byKey(const ValueKey('model-configure-custom-model'))).disabled, isTrue);
    expect(api.callsOf('providers'), hasLength(1));
    api.fail['providers'] = StateError('fixture provider unavailable');
    gate.complete();
    await settle(t);
    expect(find.textContaining('Could not load provider settings'), findsOneWidget);
    api.fail.clear();
    await open(t);
    expect(find.text('Backup'), findsOneWidget);
    expect(api.callsOf('providers'), hasLength(2));
  });

  testWidgets('model row configuration opens the existing credential editor with the selected model context', (
    t,
  ) async {
    await render(t);
    await open(t);
    await hover(t, find.byKey(const ValueKey('credential-item-c2')));
    await t.tap(find.byKey(const ValueKey('credential-edit-c2')));
    await settle(t);
    final modal = t.widget<ModelModal>(find.byType(ModelModal));
    expect(modal.model, (model: 'custom-model', modelType: 'llm'));
    expect(modal.credential?.credentialId, 'c2');
  });

  testWidgets('model row configuration is unavailable without credential permissions', (t) async {
    final api = await render(t, permissions: const ['plugin.model_config']);
    expect(find.byType(ModelCredentialsAction), findsNothing);
    expect(api.callsOf('providers'), isEmpty);
    expect(find.byKey(const ValueKey('model-remove-custom-model')), findsOneWidget);
  });
}
