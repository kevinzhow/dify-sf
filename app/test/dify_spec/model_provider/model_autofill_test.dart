import 'dart:async';

import 'package:collab_client/collab_client.dart' show ModelDiscoveryApi, TransportException;
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_autofill.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/model_fakes.dart';
import '_settings_harness.dart';

Json field(Object? value, [String source = 'provider']) => {
  'value': value,
  'source': value == null ? 'unknown' : source,
};
Json model(String id, {int? context = 500000, int? output = 128000}) => {
  'id': id,
  'fields': {
    'display_name': field(id),
    'api_type': field('responses'),
    'context_capacity': field(context),
    'output_capacity': field(output),
    'vision': field(true),
    'reasoning': field(true),
    'tools': field(null),
  },
};
Json get provider => {
  'provider': compatibleDiscoveryProvider,
  'allow_custom_token': true,
  'supported_model_types': ['llm'],
  'model_credential_schema': {
    'credential_form_schemas': [
      {'variable': 'display_name', 'type': 'text-input', 'label': 'Display name'},
      {'variable': 'context_size', 'type': 'text-input', 'label': 'Context', 'required': true, 'default': '4096'},
      {'variable': 'max_tokens_to_sample', 'type': 'text-input', 'label': 'Output', 'default': '1024'},
      {
        'variable': 'api_type',
        'type': 'select',
        'label': 'API type',
        'default': 'chat_completions',
        'options': [
          {'value': 'responses', 'label': 'Responses'},
          {'value': 'chat_completions', 'label': 'Chat'},
        ],
      },
    ],
  },
};

class DiscoveryApi extends RecordingModelsApi implements ModelDiscoveryApi {
  int discoveries = 0, probes = 0;
  bool fails = false;
  Json? discoveryData;
  Completer<Json>? pendingDiscovery, pendingProbe;
  Json? saved;
  @override
  Future<Json> discoverModels(String provider, {required Json credentials}) async {
    discoveries++;
    if (fails) throw const TransportException('Check the address and key');
    return pendingDiscovery?.future ??
        (discoveryData != null ? Future.value(discoveryData!) : Future.value({
          'discovery_id': 'receipt',
          'models': [model('listed/m')],
          'incomplete': false,
        }));
  }

  @override
  Future<Json> probeModel(
    String provider, {
    required Json credentials,
    required String model,
    required String apiType,
    required bool consent,
  }) async {
    probes++;
    expect(consent, isTrue);
    return pendingProbe?.future ??
        Future.value({
          'probe_id': 'probe',
          'id': model,
          'protocol': apiType,
          'fields': {
            'api_type': field(apiType, 'observed'),
            'tools': field(true, 'observed'),
            'output_limit': field(false, 'observed'),
          },
        });
  }

  @override
  Future<void> createAutofilledModel(
    String provider, {
    required String model,
    required Json credentials,
    String? discoveryId,
    String? probeId,
  }) async {
    saved = {'model': model, 'credentials': credentials, 'discovery_id': discoveryId, 'probe_id': probeId};
  }
}

Future<void> render(WidgetTester t, DiscoveryApi api, {List<String> permissionKeys = managerPermissionKeys}) async {
  final env = envOf(api, permissionKeys: permissionKeys);
  await renderSettings(
    t,
    ModelAutofillDialog(env: env, provider: provider, onClose: () {}),
    env: env,
  );
}

Future<void> enter(WidgetTester t, String key, String value) async {
  final f = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));
  await t.enterText(f, value);
  await t.pump();
}

Future<void> press(WidgetTester t, String label) async {
  final f = find.widgetWithText(DifyButton, label);
  await t.ensureVisible(f);
  await t.tap(f);
  await settle(t);
}

Future<void> connect(WidgetTester t) async {
  await enter(t, 'autofill-url', 'https://gateway.example/v1');
  await enter(t, 'autofill-key', 'fixture-key');
  await press(t, 'Fetch models');
}

void main() {
  testWidgets(
    'the first click on a lazy compatible provider opens autofill and its manual fallback uses the parent navigator',
    (t) async {
      final api = DiscoveryApi()..providersData = [provider];
      final env = envOf(api);
      await renderSettings(t, LazyCustomModelActions(provider: provider), env: env);
      expect(api.callsOf('providers'), isEmpty);
      await t.tap(find.text('common.modelProvider.addModel'));
      await settle(t);
      expect(find.byType(ModelAutofillDialog), findsOneWidget);
      expect(api.callsOf('providers'), hasLength(1));
      expect(api.discoveries, 0);
      await press(t, 'Full manual form');
      expect(find.byType(ModelAutofillDialog), findsNothing);
      expect(find.byType(ModelModal), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('fetch does no paid probe; add uses the same connection and receipt', (t) async {
    final api = DiscoveryApi();
    await render(t, api);
    await connect(t);
    expect(api.discoveries, 1);
    expect(api.probes, 0);
    expect(find.text('500000'), findsOneWidget);
    expect(find.textContaining('Tool calls · Unknown'), findsOneWidget);
    await press(t, 'Add model');
    final credentials = api.saved!['credentials']! as Map;
    expect(credentials['endpoint_url'], 'https://gateway.example/v1');
    expect(credentials['api_key'], 'fixture-key');
    expect(credentials['context_size'], '500000');
    expect(credentials['api_type'], 'responses');
    expect(api.saved!['discovery_id'], 'receipt');
    expect(api.probes, 0);
    expect(find.text('Model added. It is now available in workflows.'), findsOneWidget);
  });
  testWidgets('unknown capacity remains unknown; probing requires a second explicit click', (t) async {
    final api = DiscoveryApi();
    await render(t, api);
    await connect(t);
    await press(t, 'Not listed? Enter the complete name');
    await enter(t, 'autofill-model', 'outside/alias');
    expect(find.text('Unknown'), findsNWidgets(4));
    expect(api.probes, 0);
    await press(t, 'Probe common capabilities');
    expect(api.probes, 0);
    expect(find.textContaining('Sends up to 7 requests'), findsOneWidget);
    await press(t, 'Confirm probe; charges may apply');
    expect(api.probes, 1);
    expect(find.textContaining('did not enforce'), findsOneWidget);
    await press(t, 'Add model');
    final credentials = api.saved!['credentials']! as Map;
    expect(credentials['context_size'], '4096');
    expect(credentials['max_tokens_to_sample'], '1024');
    expect(credentials['function_calling_type'], 'tool_call');
    expect(api.saved!['probe_id'], 'probe');
  });
  testWidgets(
    'official reference fills reasoning and preserves source without a paid probe',
    (t) async {
      final api = DiscoveryApi()
        ..discoveryData = {
          'discovery_id': 'official-receipt',
          'models': [
            {
              'id': 'gpt-6.1-terra',
              'tool_api_type': 'responses',
              'fields': {
                for (final entry in {
                  'api_type': 'responses',
                  'context_capacity': 1050000,
                  'output_capacity': 128000,
                  'reasoning': true,
                  'reasoning_levels': [
                    'none',
                    'low',
                    'medium',
                    'high',
                    'xhigh',
                    'max',
                  ],
                  'tools': true,
                  'json_schema': true,
                  'vision': true,
                  'streaming': true,
                }.entries)
                  entry.key: field(entry.value, 'reference'),
              },
            },
          ],
        };
      await render(t, api);
      await connect(t);
      expect(
        find.textContaining('Reasoning · Supported · Official documentation'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Tool calls · Supported · Official documentation'),
        findsOneWidget,
      );
      await press(t, 'Add model');
      final credentials = api.saved!['credentials'] as Map;
      expect(credentials['api_type'], 'responses');
      expect(credentials['agent_thought_support'], 'only_thinking_supported');
      expect(credentials['function_calling_type'], 'tool_call');
      expect(credentials['structured_output_support'], 'supported');
      expect(credentials['context_size'], '1050000');
      expect(api.probes, 0);
    },
  );
  testWidgets(
    'unknown capability keeps its state and shows safe probe diagnostics',
    (t) async {
      final api = DiscoveryApi()..pendingProbe = Completer<Json>();
      await render(t, api);
      await connect(t);
      await press(t, 'Probe common capabilities');
      await press(t, 'Confirm probe; charges may apply');
      api.pendingProbe!.complete({
        'probe_id': 'failed-proof',
        'id': 'listed/m',
        'protocol': 'responses',
        'fields': {'tools': field(null)},
        'diagnostics': {
          'tools': {
            'reason': 'http_error',
            'http_status': 400,
            'code': 'unsupported_parameter',
          },
        },
      });
      await settle(t);
      expect(
        find.textContaining('Unknown does not mean unsupported.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('HTTP 400 · unsupported_parameter'),
        findsOneWidget,
      );
      expect(find.textContaining('Tool calls · Unknown'), findsOneWidget);
    },
  );
  testWidgets('connection failure preserves values and allows retry', (t) async {
    final api = DiscoveryApi()..fails = true;
    await render(t, api);
    await connect(t);
    expect(find.text('Check the address and key'), findsOneWidget);
    expect(t.widget<DifyInput>(find.byKey(const ValueKey('autofill-url'))).value, 'https://gateway.example/v1');
    expect(t.widget<DifyInput>(find.byKey(const ValueKey('autofill-key'))).value, 'fixture-key');
    api.fails = false;
    await press(t, 'Fetch models');
    expect(find.text('500000'), findsOneWidget);
    expect(api.discoveries, 2);
  });
  testWidgets('changing connection while fetching discards the late answer', (t) async {
    final api = DiscoveryApi()..pendingDiscovery = Completer<Json>();
    await render(t, api);
    await connect(t);
    await enter(t, 'autofill-url', 'https://other.example/v1');
    api.pendingDiscovery!.complete({
      'discovery_id': 'stale',
      'models': [model('stale/model')],
    });
    await settle(t);
    expect(find.text('500000'), findsNothing);
    expect(find.text('Fetch models'), findsOneWidget);
    expect(find.text('stale/model'), findsNothing);
  });
  testWidgets('manual budgets survive refreshing and can be restored', (t) async {
    final api = DiscoveryApi();
    await render(t, api);
    await connect(t);
    await press(t, 'Advanced settings');
    final inputs = find.byType(EditableText);
    // Search, display name, context usage budget, output usage budget.
    final contextField = inputs.evaluate().where((e) => (e.widget as EditableText).controller.text == '500000').single;
    await t.enterText(find.byWidget(contextField.widget), '8000');
    await t.pump();
    await press(t, 'Refresh list');
    expect(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == '8000'), findsOneWidget);
    await press(t, 'Restore automatic settings');
    expect(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == '500000'), findsOneWidget);
    expect(find.text('500000'), findsNWidgets(2));
  });
  testWidgets('manual model changes discard pending probes and their receipts', (t) async {
    final api = DiscoveryApi()..pendingProbe = Completer<Json>();
    await render(t, api);
    await connect(t);
    await press(t, 'Not listed? Enter the complete name');
    await enter(t, 'autofill-model', 'first');
    await press(t, 'Probe common capabilities');
    await press(t, 'Confirm probe; charges may apply');
    await enter(t, 'autofill-model', 'second');
    api.pendingProbe!.complete({
      'probe_id': 'stale',
      'id': 'first',
      'protocol': 'chat_completions',
      'fields': {'tools': field(true, 'observed')},
    });
    await settle(t);
    await press(t, 'Add model');
    expect(api.saved!['model'], 'second');
    expect(api.saved!['probe_id'], isNull);
    expect((api.saved!['credentials'] as Map)['function_calling_type'], 'no_call');
  });
  testWidgets('member without credential permission cannot send discovery', (t) async {
    final api = DiscoveryApi();
    await render(t, api, permissionKeys: const []);
    await enter(t, 'autofill-url', 'https://gateway.example/v1');
    await press(t, 'Fetch models');
    expect(api.discoveries, 0);
    expect(api.saved, isNull);
  });
  testWidgets('300 and 390 pixel dialogs scroll without overflow', (t) async {
    final api = DiscoveryApi();
    await render(t, api);
    for (final width in [300.0, 390.0]) {
      t.view.physicalSize = Size(width, 844);
      await t.pump();
      expect(t.takeException(), isNull);
    }
    await connect(t);
    await press(t, 'Advanced settings');
    expect(t.takeException(), isNull);
  });
}
