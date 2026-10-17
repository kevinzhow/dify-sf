// The plugin trigger, the data source checks and the start block list (Dify has no specs for these): checkValid,
// use-config's parameter handling, the panel's form and outputs, the subscription status, TagInput's refusals and
// the start block search.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/start_placeholder/start_placeholder_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_plugin/plugin_form.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_plugin/trigger_plugin_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_harness.dart';

String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
    params.isEmpty ? key : '$key:${params['field']}';

final provider = <String, Object?>{
  'name': 'github',
  'id': 'langgenius/github/github',
  'plugin_id': 'langgenius/github',
  'type': 'builtin',
  'author': 'langgenius',
  'label': {'en_US': 'GitHub'},
  'events': [
    {
      'name': 'issue_opened',
      'label': {'en_US': 'Issue opened'},
      'description': {'en_US': 'An issue was opened'},
      'parameters': [
        {
          'name': 'repo',
          'type': 'string',
          'required': true,
          'label': {'en_US': 'Repository'},
          'default': 'dify',
        },
        {
          'name': 'labels',
          'type': 'select',
          'label': {'en_US': 'Labels'},
          'options': [
            {
              'value': 'bug',
              'label': {'en_US': 'Bug'},
            },
            {
              'value': 'feat',
              'label': {'en_US': 'Feature'},
            },
          ],
        },
      ],
      'output_schema': {
        'properties': {
          'title': {'type': 'string', 'description': 'Issue title'},
          'issue': {
            'type': 'object',
            'properties': {
              'number': {'type': 'number'},
            },
          },
        },
      },
    },
  ],
};

Map<String, Object?> triggerData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Issue opened',
  ...triggerPluginDefaultValue,
  'plugin_id': 'langgenius/github',
  'provider_id': 'github',
  'provider_name': 'github',
  'event_name': 'issue_opened',
  ...overrides,
};

void main() {
  setUp(useDifyTestTranslator);

  group('trigger-plugin checkValid', () {
    test('requires a subscription first', () {
      expect(checkValidTriggerPlugin(triggerData(), t, null), 'nodes.triggerPlugin.subscriptionRequired');
    });

    test('checks required event parameters once providers are loaded', () {
      final data = triggerData({'subscription_id': 's1'});
      final params = getTriggerCheckParams(data, [provider], 'en_US');
      expect(checkValidTriggerPlugin(data, t, params), 'errorMsg.fieldRequired:Repository');
      expect(checkValidTriggerPlugin(data, t, getTriggerCheckParams(data, null, 'en_US')), '');
      final filled = triggerData({
        'subscription_id': 's1',
        'event_parameters': {
          'repo': {'type': 'constant', 'value': 'dify'},
        },
      });
      expect(checkValidTriggerPlugin(filled, t, params), '');
      final legacy = triggerData({
        'subscription_id': 's1',
        'config': {'repo': 'dify'},
      });
      expect(checkValidTriggerPlugin(legacy, t, params), '');
      final emptyVariable = triggerData({
        'subscription_id': 's1',
        'event_parameters': {
          'repo': {'type': 'variable', 'value': <Object?>[]},
        },
      });
      expect(checkValidTriggerPlugin(emptyVariable, t, params), 'errorMsg.fieldRequired:Repository');
    });
  });

  group('trigger-plugin use-config', () {
    test('normalizes event parameters', () {
      expect(
        normalizeEventParameters({
          'a': {'type': 'mixed', 'value': 'x'},
          'b': '',
          'c': 0,
          'd': 'plain',
        }),
        {
          'a': {'type': 'constant', 'value': 'x'},
        },
      );
      expect(
        normalizeEventParameters({
          'c': 0,
          'd': 'plain',
          'e': ['n', 'v'],
          'f': false,
        }, allowScalars: true),
        {
          'c': {'type': 'constant', 'value': 0},
          'd': {'type': 'constant', 'value': 'plain'},
          'e': {
            'type': 'variable',
            'value': ['n', 'v'],
          },
          'f': {'type': 'constant', 'value': false},
        },
      );
    });

    test('fills the parameters from the schema defaults once', () {
      final event = findTriggerEvent(findTriggerProvider([provider], triggerData()), 'issue_opened');
      final schema = triggerParameterSchemaOf(event);
      expect([for (final s in schema) s['type']], ['text-input', 'select']);
      final next = triggerPluginInitialFill(triggerData(), schema)!;
      expect(next['event_parameters'], {
        'repo': {'type': 'constant', 'value': 'dify'},
      });
      expect(next['config'], next['event_parameters']);
      expect(triggerPluginInitialFill(next, schema), isNull);
    });

    testWidgets('the panel shows the form once subscribed and the event outputs', (tester) async {
      final h = await Harness.start(tester, [
        difyNode('n1', 'trigger-plugin', triggerData({'subscription_id': 's1'})),
      ]);
      await pumpBody(
        tester,
        h,
        'n1',
        triggerPluginPanelBody,
        wrap: (child) => TriggerPluginHost(
          providers: [provider],
          subscriptionsOf: (id) => id == 'github'
              ? [
                  {'id': 's1', 'name': 'Main'},
                ]
              : const [],
          child: child,
        ),
      );

      expect(find.byType(PluginForm), findsOneWidget);
      expect(find.text('Repository'), findsOneWidget);
      expect(plainOf(h['n1']!.config['event_parameters']), {
        'repo': {'type': 'constant', 'value': 'dify'},
      });
      await tester.tap(find.text('workflow.nodes.common.outputVars'.toUpperCase()));
      await Harness.settle(tester);
      final vars = {for (final v in tester.widgetList<VarItem>(find.byType(VarItem))) v.name: v.type};
      expect(vars, {'title': 'string', 'issue': 'object'});
      expect(find.text('number'), findsNWidgets(2)); // the nested field and its type
      await h.dispose(tester);
    });

    testWidgets('the panel hides the form without a valid subscription', (tester) async {
      final h = await Harness.start(tester, [
        difyNode('n1', 'trigger-plugin', triggerData({'subscription_id': 'gone'})),
      ]);
      await pumpBody(
        tester,
        h,
        'n1',
        triggerPluginPanelBody,
        wrap: (child) => TriggerPluginHost(providers: [provider], child: child),
      );
      expect(find.byType(PluginForm), findsNothing);
      await h.dispose(tester);
    });
  });

  group('subscription selector', () {
    test('labels the selection state', () {
      final subs = [
        {'id': 's1', 'name': 'Main'},
      ];
      expect(SubscriptionSelectorEntry.status(subs, null, open: false), (
        'plugin-trigger.subscription.noSubscriptionSelected',
        true,
      ));
      expect(SubscriptionSelectorEntry.status(subs, '', open: true), (
        'plugin-trigger.subscription.selectPlaceholder',
        false,
      ));
      expect(SubscriptionSelectorEntry.status(subs, 'x', open: false), (
        'plugin-trigger.subscription.subscriptionRemoved',
        true,
      ));
      expect(SubscriptionSelectorEntry.status(subs, 's1', open: false), ('Main', false));
    });
  });

  group('data source checkValid', () {
    final list = [
      {
        'plugin_id': 'p',
        'allow_delete': true,
        'is_authorized': false,
        'tools': [
          {
            'name': 'crawl',
            'parameters': [
              {
                'name': 'url',
                'type': 'string',
                'required': true,
                'label': {'en_US': 'URL'},
              },
            ],
          },
        ],
      },
    ];
    final data = {
      'plugin_id': 'p',
      'provider_type': 'website_crawl',
      'datasource_name': 'crawl',
      'datasource_parameters': <String, Object?>{},
    };

    test('requires authorization, then the required parameters', () {
      expect(checkValidDataSource(data, t, getDataSourceCheckParams(data, list, 'en_US')), 'errorMsg.authRequired');
      final authed = [
        {...list.first, 'is_authorized': true},
      ];
      expect(
        checkValidDataSource(data, t, getDataSourceCheckParams(data, authed, 'en_US')),
        'errorMsg.fieldRequired:URL',
      );
      final filled = {
        ...data,
        'datasource_parameters': {
          'url': {'type': 'mixed', 'value': 'https://dify.ai'},
        },
      };
      expect(checkValidDataSource(filled, t, getDataSourceCheckParams(filled, authed, 'en_US')), '');
      expect(checkValidDataSourceEmpty(const {}, t, null), '');
      expect(checkValidStartPlaceholder(const {}, t, null), 'nodes.startPlaceholder.validationRequired');
    });

    test('lists the output variables', () {
      final local = {...data, 'provider_type': 'local_file'};
      expect([for (final v in dataSourceOutputVars(local, list)) v['variable']], ['datasource_type', 'file']);
    });
  });

  group('TagInput', () {
    testWidgets('refuses duplicates and long tags', (tester) async {
      final errors = <String>[];
      var items = ['pdf'];
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: StatefulBuilder(
              builder: (context, setState) => TagInput(
                items: items,
                onChange: (v) => setState(() => items = v),
                onError: errors.add,
              ),
            ),
          ),
        ),
      );
      final field = find.byType(EditableText);
      await tester.enterText(field, ' pdf ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.enterText(field, 'a' * 21);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.enterText(field, 'md');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(errors, ['dataset-documents.segment.keywordDuplicate', 'dataset-documents.segment.keywordError']);
      expect(items, ['pdf', 'md']);
      await tester.tap(find.bySemanticsLabel('common.operation.remove pdf'));
      await tester.pump();
      expect(items, ['md']);
    });
  });

  group('AllStartBlocks', () {
    testWidgets('filters the start blocks and trigger plugins, with an empty state', (tester) async {
      final picked = <List<Object?>>[];
      Future<void> pump(String search, {bool hasStartNode = false}) => tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: SingleChildScrollView(
              child: AllStartBlocks(
                searchText: search,
                triggerProviders: [provider],
                hasStartNode: hasStartNode,
                allowUserInputSelection: true,
                onSelect: (type, [trigger]) => picked.add([type, trigger]),
              ),
            ),
          ),
        ),
      );
      await pump('');
      expect(find.text('workflow.blocks.start'), findsOneWidget);
      expect(find.text('workflow.blocks.mostCommon'.toUpperCase()), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      await pump('', hasStartNode: true);
      expect(find.text('workflow.blocks.start'), findsNothing);

      await pump('issue');
      expect(find.text('workflow.blocks.trigger-schedule'), findsNothing);
      await tester.tap(find.text('Issue opened'));
      expect(picked.single[0], 'trigger-plugin');
      final trigger = picked.single[1]! as Map<String, Object?>;
      expect(trigger['event_name'], 'issue_opened');
      expect(trigger['params'], {'repo': '', 'labels': ''});
      final data = startNodeDataOf('trigger-plugin', startBlockDefaults(), trigger)!;
      expect(data['title'], 'Issue opened');
      expect(data['provider_id'], 'github');
      expect(data['config'], {'repo': '', 'labels': ''});

      await pump('zzz');
      expect(find.text('workflow.nodes.startPlaceholder.noTriggersFound'), findsOneWidget);
    });
  });
}
