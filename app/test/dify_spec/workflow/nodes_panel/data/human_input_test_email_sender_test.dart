// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/test-email-sender.spec.tsx
//
// The delivery test request is the host's `sendTestEmail` (Dify posts `/delivery-test`); the JSON field's Monaco
// mock is the code editor's change callback.
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/test_email_sender.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

Map<String, Object?> createConfig([Map<String, Object?> overrides = const {}]) => {
  'recipients': {'whole_workspace': true, 'items': <Object?>[]},
  'subject': 'Review request',
  'body': 'Please review {{#start.score#}}',
  'debug_mode': false,
  ...overrides,
};

const formInput = {
  'type': 'paragraph',
  'output_variable_name': 'user_name',
  'default': {
    'type': 'variable',
    'selector': ['start', 'user_name'],
    'value': '',
  },
};

const dynamicSelectInput = {
  'type': 'select',
  'output_variable_name': 'decision',
  'option_source': {
    'type': 'variable',
    'selector': ['code', 'result'],
    'value': <Object?>[],
  },
};

void main() {
  late List<({String nodeId, String deliveryId, Map<String, Object?> inputs})> sent;
  late List<bool> results;
  late Toasts toasts;

  setUp(() {
    sent = [];
    results = [];
    toasts = Toasts();
  });

  Future<void> send({required String nodeId, required String deliveryId, required Map<String, Object?> inputs}) async =>
      sent.add((nodeId: nodeId, deliveryId: deliveryId, inputs: inputs));

  Future<void> open(WidgetTester t, Map<String, Object?> config, {EmailContext? email}) async {
    await pumpComponent(
      t,
      Opener<bool>(
        results: results,
        open: (c) => showTestEmailSender(
          c,
          deliveryId: 'delivery-1',
          config: config,
          email: email ?? const EmailContext(nodeId: 'human-node'),
        ),
      ),
      toasts: toasts,
      wrap: (c) => host(c, sendTestEmail: send),
    );
    await tapAndSettle(t, find.text('open'));
  }

  String s(String key) => hiKey('deliveryMethod.emailSender.$key');
  Finder sendButton() => find.widgetWithText(DifyButton, s('send'));
  bool sendEnabled(WidgetTester t) => !t.widget<DifyButton>(sendButton()).disabled;
  Finder placeholder(String text) => find.descendant(
    of: find.byWidgetPredicate((w) => w is DifyInput && w.placeholder == text),
    matching: find.byType(EditableText),
  );

  const codeNode = WorkflowNodeInfo(title: 'Code', type: 'code');

  group('human-input/delivery-method/test-email-sender', () {
    testWidgets('should submit generated variable inputs and show the success state', (t) async {
      await open(
        t,
        createConfig(),
        email: const EmailContext(
          nodeId: 'human-node',
          formInputs: [formInput],
          nodesMap: {'start': WorkflowNodeInfo(title: 'Start', type: 'start')},
          vars: [
            VarGroup(
              nodeId: 'start',
              title: 'Start',
              vars: [PickerVar('user_name', 'string'), PickerVar('score', 'number')],
            ),
          ],
        ),
      );
      expect(sendEnabled(t), isFalse);

      await t.enterText(placeholder('user_name'), 'Ada');
      await t.enterText(placeholder('score'), '42');
      await t.pump();
      expect(sendEnabled(t), isTrue);
      await tapAndSettle(t, sendButton());

      expect(find.text(s('done')), findsOneWidget);
      expect(sent.single.nodeId, 'human-node');
      expect(sent.single.deliveryId, 'delivery-1');
      expect(sent.single.inputs, {'#start.user_name#': 'Ada', '#start.score#': 42});

      await tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.ok'));
      expect(results, [false]);
    });

    testWidgets('should start a fresh session after closing and reopening', (t) async {
      await open(t, createConfig({'body': ''}));
      await tapAndSettle(t, sendButton());
      expect(find.text(s('done')), findsOneWidget);
      await tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.ok'));
      expect(find.byType(TestEmailSender), findsNothing);

      await tapAndSettle(t, find.text('open'));
      expect(sendButton(), findsOneWidget);
      expect(find.text(s('done')), findsNothing);
      await tapAndSettle(t, sendButton());
      expect(sent, hasLength(2));
    });

    testWidgets('should stay open when clicking outside the dialog', (t) async {
      await open(t, createConfig({'body': ''}));
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(TestEmailSender), findsOneWidget);
      expect(results, isEmpty);
    });

    testWidgets('should submit variables referenced by dynamic select option sources', (t) async {
      await open(
        t,
        createConfig({'body': '{{#url#}}'}),
        email: const EmailContext(
          nodeId: 'human-node',
          formInputs: [dynamicSelectInput],
          nodesMap: {'code': codeNode},
          vars: [
            VarGroup(nodeId: 'code', title: 'Code', vars: [PickerVar('result', 'array[string]')]),
          ],
        ),
      );
      expect(sendEnabled(t), isFalse);
      expect(placeholder('result'), findsNothing);

      t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('["approve","reject"]');
      await t.pump();
      expect(sendEnabled(t), isTrue);
      await tapAndSettle(t, sendButton());

      expect(sent.single.inputs, {
        '#code.result#': ['approve', 'reject'],
      });
    });

    testWidgets('should render fallback variable inputs and allow cancelling', (t) async {
      await open(t, createConfig({'body': 'Please review {{#unknown.message#}}'}));
      expect(placeholder('message'), findsOneWidget);

      await tapNamed(t, s('vars'));
      expect(placeholder('message'), findsNothing);

      await tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.cancel'));
      expect(results, [false]);
    });

    testWidgets('should show selected recipients with the email configuration tip', (t) async {
      await open(
        t,
        createConfig({
          'recipients': {
            'whole_workspace': true,
            'items': [
              {'type': 'external', 'email': 'external@example.com'},
            ],
          },
          'body': 'Please review {{#url#}}',
        }),
      );
      expect(find.text('external@example.com'), findsOneWidget);
      expect(find.textContaining(s('tip')), findsOneWidget);
    });

    testWidgets('should show a validation toast when generated JSON input is invalid', (t) async {
      await open(
        t,
        createConfig({'body': 'Please review {{#code.payload#}}'}),
        email: const EmailContext(
          nodeId: 'human-node',
          nodesMap: {'code': codeNode},
          vars: [
            VarGroup(nodeId: 'code', title: 'Code', vars: [PickerVar('payload', 'object')]),
          ],
        ),
      );
      t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('{invalid');
      await t.pump();
      await tapAndSettle(t, sendButton());

      expect(errorsOf(toasts), ['workflow.errorMsg.invalidJson:{"field":"payload"}']);
      expect(sent, isEmpty);
    });

    testWidgets('should show debug success copy after sending in debug mode', (t) async {
      await open(t, createConfig({'body': 'Plain body', 'debug_mode': true}));
      expect(find.text(s('debugModeTip')), findsOneWidget);
      await tapAndSettle(t, sendButton());
      expect(find.textContaining(s('debugDone')), findsOneWidget);
    });

    testWidgets('should show specific-recipient success copy after sending', (t) async {
      await open(
        t,
        createConfig({
          'body': 'Plain body',
          'recipients': {
            'whole_workspace': false,
            'items': [
              {'type': 'external', 'email': 'external@example.com'},
            ],
          },
        }),
      );
      await tapAndSettle(t, sendButton());
      expect(find.textContaining(s('wholeTeamDone3')), findsOneWidget);
      expect(find.text('external@example.com'), findsOneWidget);
    });
  });
}
