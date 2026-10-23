// dify-spec: web/app/components/workflow/utils/__tests__/trigger.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_plugin/trigger_plugin_default.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _triggerData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Trigger',
  'desc': '',
  'type': 'trigger-plugin',
  'provider_id': 'provider-1',
  'provider_type': 'builtin',
  'provider_name': 'my-provider',
  'event_name': 'on_message',
  'event_label': 'On Message',
  'event_parameters': <String, Object?>{},
  'event_configurations': <String, Object?>{},
  'output_schema': <String, Object?>{},
  ...overrides,
};

Map<String, Object?> _provider([Map<String, Object?> overrides = const {}]) => {
  'id': 'provider-1',
  'name': 'my-provider',
  'plugin_id': 'plugin-1',
  'events': [
    {
      'name': 'on_message',
      'label': {'en_US': 'On Message', 'zh_Hans': '收到消息'},
      'parameters': [
        {
          'name': 'channel',
          'label': {'en_US': 'Channel', 'zh_Hans': '频道'},
          'required': true,
        },
        {
          'name': 'filter',
          'label': {'en_US': 'Filter'},
          'required': false,
        },
      ],
    },
  ],
  ...overrides,
};

Object? _firstLabel(Map<String, Object?> result) => ((result['triggerInputsSchema'] as List)[0] as Map)['label'];

void main() {
  group('getTriggerCheckParams', () {
    test('should return empty schema when triggerProviders is undefined', () {
      expect(getTriggerCheckParams(_triggerData(), null, 'en_US'), {
        'triggerInputsSchema': <Object?>[],
        'isReadyForCheckValid': false,
      });
    });

    test('should match provider by name and extract parameters', () {
      final result = getTriggerCheckParams(_triggerData(), [_provider()], 'en_US');
      expect(result['isReadyForCheckValid'], isTrue);
      expect(result['triggerInputsSchema'], [
        {'variable': 'channel', 'label': 'Channel', 'required': true},
        {'variable': 'filter', 'label': 'Filter', 'required': false},
      ]);
    });

    test('should use the requested language for labels', () {
      expect(_firstLabel(getTriggerCheckParams(_triggerData(), [_provider()], 'zh_Hans')), '频道');
    });

    test('should fall back to en_US when language label is missing', () {
      expect(_firstLabel(getTriggerCheckParams(_triggerData(), [_provider()], 'ja_JP')), 'Channel');
    });

    test('should fall back to parameter name when no labels exist', () {
      final provider = _provider({
        'events': [
          {
            'name': 'on_message',
            'label': {'en_US': 'On Message'},
            'parameters': [
              {'name': 'raw_param'},
            ],
          },
        ],
      });
      expect(_firstLabel(getTriggerCheckParams(_triggerData(), [provider], 'en_US')), 'raw_param');
    });

    test('should match provider by provider_id', () {
      final trigger = _triggerData({'provider_name': 'different-name', 'provider_id': 'provider-1'});
      final provider = _provider({'name': 'other-name', 'id': 'provider-1'});
      final result = getTriggerCheckParams(trigger, [provider], 'en_US');
      expect(result['isReadyForCheckValid'], isTrue);
      expect(result['triggerInputsSchema'], hasLength(2));
    });

    test('should match provider by plugin_id', () {
      final trigger = _triggerData({'provider_name': 'x', 'provider_id': 'plugin-1'});
      final provider = _provider({'name': 'y', 'id': 'z', 'plugin_id': 'plugin-1'});
      final result = getTriggerCheckParams(trigger, [provider], 'en_US');
      expect(result['isReadyForCheckValid'], isTrue);
      expect(result['triggerInputsSchema'], hasLength(2));
    });

    test('should return empty schema when event is not found', () {
      final result = getTriggerCheckParams(_triggerData({'event_name': 'non_existent_event'}), [_provider()], 'en_US');
      expect(result['triggerInputsSchema'], isEmpty);
      expect(result['isReadyForCheckValid'], isTrue);
    });
  });
}
