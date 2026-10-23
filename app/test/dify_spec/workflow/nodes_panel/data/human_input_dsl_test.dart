// dify-spec: web/app/components/workflow/nodes/human-input/__tests__/human-input.spec.tsx
//
// Dify's DSL import (preprocessNodesAndEdges, initialNodes) is dify-sf's converter (nodeFromDify / difyNodeOf):
// the cases check that a Human Input node goes through it unchanged. The card is the canvas body (HumanInputBody,
// which applies the CSS transforms: `capitalize` methods, `uppercase` action IDs).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow/output_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/node_meta.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart' show difyNodesMetaData;
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/node_validators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `withSelectorKey((key) => key, 'workflow')`.
String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

Map<String, Object?> createHumanInputData([Map<String, Object?> overrides = const {}]) => {
  'type': 'human-input',
  'title': 'Human Input',
  'desc': 'Wait for human input',
  'delivery_methods': [
    {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
    {
      'id': 'dm-2',
      'type': 'email',
      'enabled': true,
      'config': {
        'recipients': {'whole_workspace': false, 'items': <Object?>[]},
        'subject': 'Please review',
        'body': 'Please review the form',
        'debug_mode': false,
      },
    },
  ],
  'form_content': '# Review Form\nPlease fill in the details below.',
  'inputs': [
    {
      'type': 'text-input',
      'output_variable_name': 'review_result',
      'default': {'selector': <Object?>[], 'type': 'constant', 'value': ''},
    },
  ],
  'user_actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
    {'id': 'reject', 'title': 'Reject', 'button_style': 'default'},
  ],
  'timeout': 3,
  'timeout_unit': 'day',
  ...overrides,
};

Map<String, Object?> createHumanInputNode([Map<String, Object?> overrides = const {}]) => {
  'id': 'human-input-1',
  'type': 'custom',
  'position': {'x': 400, 'y': 200},
  'data': createHumanInputData(overrides),
};

Map<String, Object?> createStartNode() => {
  'id': 'inset-s-1',
  'type': 'custom',
  'position': {'x': 100, 'y': 200},
  'data': {'type': 'start', 'title': 'Start', 'desc': ''},
};

Map<String, Object?> createEndNode(String id) => {
  'id': id,
  'type': 'custom',
  'position': {'x': 700, 'y': 200},
  'data': {'type': 'end', 'title': 'End', 'desc': '', 'outputs': <Object?>[]},
};

/// The DSL nodes through the converter and back.
List<Map<String, Object?>> roundTrip(List<Map<String, Object?>> nodes) {
  final doc = Document();
  return [for (final n in nodes) difyNodeOf(nodeFromDify(n, doc, id: n['id']! as String))];
}

Map<String, Object?> payload(Map<String, Object?> patch) => {
  'type': 'human-input',
  ...humanInputDefaultValue,
  ...patch,
};

String check(Map<String, Object?> data) => nodeCheckValid['human-input']!(data, t, null);

Future<void> renderCard(WidgetTester tester, Map<String, Object?> data) {
  final node = nodeFromDify(
    {
      'id': 'human-input-1',
      'position': {'x': 0, 'y': 0},
      'data': data,
    },
    Document(),
    id: 'human-input-1',
  );
  return tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 238,
            child: Builder(builder: (c) => const HumanInputBody().build(c, BodyContext(node, (_) => null))),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('DSL Import with Human Input Node', () {
    group('preprocessNodesAndEdges', () {
      test('should pass through a workflow containing a human-input node unchanged', () {
        final nodes = [createStartNode(), createHumanInputNode()];
        final result = roundTrip(nodes);
        expect(result, hasLength(2));
        expect(result[1]['data'], nodes[1]['data']);
        expect(result[1]['position'], nodes[1]['position']);
      });

      test('should not treat human-input node as an iteration or loop node', () {
        final result = roundTrip([createHumanInputNode()]);
        expect(result, hasLength(1));
        expect((result[0]['data']! as Map)['type'], 'human-input');
      });
    });

    group('initialNodes', () {
      test('should preserve human-input node data after initialization', () {
        final data = roundTrip([createHumanInputNode()])[0]['data']! as Map;
        expect(data['delivery_methods'], hasLength(2));
        expect(data['user_actions'], hasLength(2));
        expect(data['form_content'], '# Review Form\nPlease fill in the details below.');
        expect(data['timeout'], 3);
        expect(data['timeout_unit'], 'day');
      });

      test('should set node type to custom if not set', () {
        final node = createHumanInputNode()..remove('type');
        expect(roundTrip([node])[0]['type'], 'custom');
      });
    });

    group('HumanInputNode Component', () {
      testWidgets('should display delivery method labels when methods are present', (tester) async {
        await renderCard(tester, createHumanInputData());
        expect(find.text('Webapp'), findsOneWidget);
        expect(find.text('Email'), findsOneWidget);
      });

      testWidgets('should display user action IDs', (tester) async {
        await renderCard(tester, createHumanInputData());
        expect(find.text('APPROVE'), findsOneWidget);
        expect(find.text('REJECT'), findsOneWidget);
      });

      testWidgets('should always display Timeout handle', (tester) async {
        await renderCard(tester, createHumanInputData());
        expect(find.text('TIMEOUT'), findsOneWidget);
      });

      testWidgets('should hide delivery method labels when no methods are configured', (tester) async {
        await renderCard(tester, createHumanInputData({'delivery_methods': <Object?>[]}));
        expect(find.text('Webapp'), findsNothing);
        expect(find.text('Email'), findsNothing);
      });

      testWidgets('should keep the timeout branch when no user actions are configured', (tester) async {
        await renderCard(tester, createHumanInputData({'user_actions': <Object?>[]}));
        expect(find.text('TIMEOUT'), findsOneWidget);
      });

      testWidgets('should render with only webapp delivery method', (tester) async {
        await renderCard(
          tester,
          createHumanInputData({
            'delivery_methods': [
              {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
            ],
          }),
        );
        expect(find.text('Webapp'), findsOneWidget);
        expect(find.text('Email'), findsNothing);
      });

      testWidgets('should render with multiple user actions', (tester) async {
        await renderCard(
          tester,
          createHumanInputData({
            'user_actions': [
              {'id': 'action_1', 'title': 'Approve', 'button_style': 'primary'},
              {'id': 'action_2', 'title': 'Reject', 'button_style': 'default'},
              {'id': 'action_3', 'title': 'Escalate', 'button_style': 'accent'},
            ],
          }),
        );
        expect(find.text('ACTION_1'), findsOneWidget);
        expect(find.text('ACTION_2'), findsOneWidget);
        expect(find.text('ACTION_3'), findsOneWidget);
      });
    });

    group('Node Registration', () {
      test('should have HumanInput included in WORKFLOW_COMMON_NODES', () {
        // useAvailableNodesMetaData's nodes (the common nodes) in a workflow and a chatflow.
        expect(difyNodesMetaData().keys, contains('human-input'));
        expect(difyNodesMetaData(chatMode: true).keys, contains('human-input'));
        expect(nodeMetaOf('human-input'), isNotNull);
      });
    });

    group('HumanInput Default Configuration', () {
      test('should provide default values for a new human-input node', () {
        const d = humanInputDefaultValue;
        expect(d['delivery_methods'], isEmpty);
        expect(d['user_actions'], isEmpty);
        expect(d['form_content'], '');
        expect(d['inputs'], isEmpty);
        expect(d['timeout'], 3);
        expect(d['timeout_unit'], 'day');
      });

      test('should validate that delivery methods are required', () {
        expect(check(payload({'delivery_methods': <Object?>[]})), isNotEmpty);
      });

      test('should validate that at least one delivery method is enabled', () {
        final error = check(
          payload({
            'delivery_methods': [
              {'id': 'dm-1', 'type': 'webapp', 'enabled': false},
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ],
          }),
        );
        expect(error, isNotEmpty);
      });

      test('should validate that enabled email delivery methods have complete configuration', () {
        final error = check(
          payload({
            'delivery_methods': [
              {'id': 'dm-email', 'type': 'email', 'enabled': true},
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ],
          }),
        );
        expect(error, 'nodes.humanInput.errorMsg.emailConfigIncomplete');
      });

      test('should validate email delivery config fields before user actions', () {
        final error = check(
          payload({
            'delivery_methods': [
              {
                'id': 'dm-email',
                'type': 'email',
                'enabled': true,
                'config': {
                  'recipients': {'whole_workspace': false, 'items': <Object?>[]},
                  'subject': 'Review request',
                  'body': 'Please review {{#url#}}',
                  'debug_mode': false,
                },
              },
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ],
          }),
        );
        expect(error, 'nodes.humanInput.errorMsg.emailConfigIncomplete');
      });

      test('should validate enabled email subject and body content', () {
        Map<String, Object?> create(String body, [String subject = 'Review request']) => payload({
          'delivery_methods': [
            {
              'id': 'dm-email',
              'type': 'email',
              'enabled': true,
              'config': {
                'recipients': {'whole_workspace': true, 'items': <Object?>[]},
                'subject': subject,
                'body': body,
                'debug_mode': false,
              },
            },
          ],
          'user_actions': [
            {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
          ],
        });
        expect(check(create('{{#url#}}', '  ')), 'nodes.humanInput.errorMsg.emailConfigIncomplete');
        expect(check(create('Please review')), 'nodes.humanInput.errorMsg.emailConfigIncomplete');
      });

      test('should validate that user actions are required', () {
        final error = check(
          payload({
            'delivery_methods': [
              {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
            ],
            'user_actions': <Object?>[],
          }),
        );
        expect(error, isNotEmpty);
      });

      test('should validate that user action IDs are not duplicated', () {
        final error = check(
          payload({
            'delivery_methods': [
              {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
              {'id': 'approve', 'title': 'Also Approve', 'button_style': 'default'},
            ],
          }),
        );
        expect(error, isNotEmpty);
      });

      test('should validate that user action ids and titles are not empty', () {
        Map<String, Object?> create(List<Object?> actions) => payload({
          'delivery_methods': [
            {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
          ],
          'user_actions': actions,
        });
        expect(
          check(
            create([
              {'id': '  ', 'title': 'Approve', 'button_style': 'primary'},
            ]),
          ),
          'nodes.humanInput.errorMsg.emptyActionId',
        );
        expect(
          check(
            create([
              {'id': 'approve', 'title': '  ', 'button_style': 'primary'},
            ]),
          ),
          'nodes.humanInput.errorMsg.emptyActionTitle',
        );
      });

      test('should pass validation with correct configuration', () {
        final error = check(
          payload({
            'delivery_methods': [
              {'id': 'dm-1', 'type': 'webapp', 'enabled': true},
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
              {'id': 'reject', 'title': 'Reject', 'button_style': 'default'},
            ],
          }),
        );
        expect(error, '');
      });
    });

    group('HumanInput Output Variables', () {
      Node nodeWith(List<Object?> inputs) => nodeFromDify(
        {
          'id': 'hi',
          'position': {'x': 0, 'y': 0},
          'data': payload({'inputs': inputs}),
        },
        Document(),
        id: 'hi',
      );

      test('should generate output variables from form inputs', () {
        final vars = formatItem(
          'hi',
          difyDataOf(
            nodeWith([
              {
                'type': 'paragraph',
                'output_variable_name': 'review_result',
                'default': {'selector': <Object?>[], 'type': 'constant', 'value': ''},
              },
              {
                'type': 'file',
                'output_variable_name': 'attachment',
                'allowed_file_extensions': <Object?>[],
                'allowed_file_types': <Object?>[],
                'allowed_file_upload_methods': <Object?>[],
              },
              {
                'type': 'file-list',
                'output_variable_name': 'attachments',
                'allowed_file_extensions': <Object?>[],
                'allowed_file_types': <Object?>[],
                'allowed_file_upload_methods': <Object?>[],
                'number_limits': 3,
              },
              {
                'type': 'select',
                'output_variable_name': 'comment',
                'option_source': {
                  'type': 'constant',
                  'selector': <Object?>[],
                  'value': ['A', 'B'],
                },
              },
            ]),
          ),
        );
        // getOutputVars gives the form inputs; the variable list then appends HUMAN_INPUT_OUTPUT_STRUCT.
        expect(
          [for (final v in vars.take(4)) (v.variable, v.type)],
          [
            ('review_result', 'string'),
            ('attachment', 'file'),
            ('attachments', 'array[file]'),
            ('comment', 'string'),
          ],
        );
      });

      test('should return no output variables when no form inputs exist', () {
        final vars = formatItem('hi', difyDataOf(nodeWith(const [])));
        expect([for (final v in vars) v.variable], ['__action_id', '__action_value', '__rendered_content']);
      });
    });

    group('Full Workflow with Human Input Node', () {
      test('should process a start → human-input → end workflow without errors', () {
        final result = roundTrip([createStartNode(), createHumanInputNode(), createEndNode('inset-e-1')]);
        expect(result, hasLength(3));
        final types = [for (final n in result) (n['data']! as Map)['type']];
        expect(types, containsAll(['start', 'human-input', 'end']));
      });

      test('should handle multiple branches from human-input user actions', () {
        final result = roundTrip([
          createStartNode(),
          createHumanInputNode(),
          createEndNode('approve-end'),
          createEndNode('reject-end'),
        ]);
        expect(result, hasLength(4));
        final hi = result.firstWhere((n) => n['id'] == 'human-input-1')['data']! as Map;
        expect(hi['user_actions'], hasLength(2));
        expect(hi['delivery_methods'], hasLength(2));
      });
    });
  });
}
