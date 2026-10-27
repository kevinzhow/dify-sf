import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_plugins.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/model_fakes.dart';
import '_settings_harness.dart';

class PluginModelsApi extends RecordingModelsApi implements ModelProviderPluginsApi {
  List<Json> rows = [
    {
      'provider': 'langgenius/openai/openai',
      'plugin_id': 'langgenius/openai',
      'status': 'missing',
      'available_version': '1.0.7',
      'available_identifier': 'langgenius/openai:fixture',
    },
  ];
  bool listFails = false;
  bool taskFails = false;
  final installs = <String>[];
  final removals = <(String, String)>[];
  @override
  Future<List<Json>> providerPlugins() async {
    if (listFails) throw const TransportException('Plugin status could not be read');
    return [
      for (final r in rows) {...r},
    ];
  }

  @override
  Future<Json> installProviderPlugin(String pluginId) async {
    installs.add(pluginId);
    return {'task_id': 'fixture-task'};
  }

  @override
  Future<Json> providerPluginTask(String taskId) async {
    if (taskFails) return {'status': 'failed', 'error': 'Fixture install failure'};
    rows.first.addAll({
      'status': 'installed',
      'installation_id': 'installation-1',
      'installed_identifier': 'langgenius/openai:fixture',
      'installed_version': '1.0.7',
    });
    return {'status': 'success'};
  }

  @override
  Future<void> uninstallProviderPlugin(String pluginId, {required String installationId}) async {
    removals.add((pluginId, installationId));
    rows.first['status'] = 'missing';
  }
}

void main() {
  testWidgets('install follows the daemon task and refreshes model availability', (t) async {
    final api = PluginModelsApi();
    await renderSettings(t, ProviderPluginsDialog(api: api), env: envOf(api));
    await t.tap(find.byKey(const ValueKey('plugin-install-langgenius/openai')));
    await settle(t);
    expect(api.installs, ['langgenius/openai']);
    expect(find.text('common.modelProvider.plugins.installed'), findsOneWidget);
    expect(api.callsOf('modelsOfType'), isNotEmpty);
    expect(find.byKey(const ValueKey('plugin-remove-langgenius/openai')), findsOneWidget);
  });

  testWidgets('remove confirms the exact installation and retains saved model credentials', (t) async {
    final api = PluginModelsApi()
      ..modelCredentialData = {
        'credentials': {'api_key': 'fixture-masked'},
      };
    await api.providerPluginTask('fixture-task');
    await renderSettings(t, ProviderPluginsDialog(api: api), env: envOf(api));
    await t.tap(find.byKey(const ValueKey('plugin-remove-langgenius/openai')));
    await settle(t);
    expect(api.removals, isEmpty);
    expect(find.text('common.modelProvider.plugins.removeDescription'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('alert-confirm')));
    await settle(t);
    expect(api.removals, [('langgenius/openai', 'installation-1')]);
    expect(api.modelCredentialData['credentials'], {'api_key': 'fixture-masked'});
    expect(find.byKey(const ValueKey('plugin-install-langgenius/openai')), findsOneWidget);
  });

  testWidgets('read failures retain previous rows and do not invent a missing installation', (t) async {
    final api = PluginModelsApi();
    await api.providerPluginTask('fixture-task');
    await renderSettings(t, ProviderPluginsDialog(api: api), env: envOf(api));
    api.listFails = true;
    await tapButton(t, 'common.modelProvider.plugins.refresh');
    expect(find.text('Plugin status could not be read'), findsOneWidget);
    expect(find.text('common.modelProvider.plugins.installed'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-install-langgenius/openai')), findsNothing);
  });

  testWidgets('failed installs keep their error and remain retryable', (t) async {
    final api = PluginModelsApi()..taskFails = true;
    await renderSettings(t, ProviderPluginsDialog(api: api), env: envOf(api));
    await t.tap(find.byKey(const ValueKey('plugin-install-langgenius/openai')));
    await settle(t);
    expect(find.textContaining('Fixture install failure'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-install-langgenius/openai')), findsOneWidget);
    expect(api.callsOf('modelsOfType'), isEmpty);
  });

  testWidgets('members can read status but cannot install or remove plugins', (t) async {
    final api = PluginModelsApi();
    await renderSettings(
      t,
      ProviderPluginsDialog(api: api),
      env: envOf(api, permissionKeys: const []),
    );
    expect(find.text('common.modelProvider.plugins.missing'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-install-langgenius/openai')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-remove-langgenius/openai')), findsNothing);
  });

  testWidgets('the shared dialog remains usable at a phone width', (t) async {
    final api = PluginModelsApi();
    await renderSettings(t, ProviderPluginsDialog(api: api), env: envOf(api));
    t.view.physicalSize = const Size(390, 900);
    await settle(t);
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('plugin-install-langgenius/openai')), findsOneWidget);
  });
}
