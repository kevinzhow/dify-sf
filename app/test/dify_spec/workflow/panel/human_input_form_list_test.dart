// dify-spec: web/app/components/workflow/panel/__tests__/human-input-form-list.spec.tsx
// dify-spec: web/app/components/workflow/panel/__tests__/human-input-filled-form-list.spec.tsx
//
// The test run panel's lists are HumanInputFormList / HumanInputFilledFormList with `inPanel`; the form's node data
// (React Flow's nodes in Dify) comes from `getHumanInputNodeData`.
import 'dart:ui' show Tristate;

import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

DifyJson createFormData([Map<String, Object?> o = const {}]) => {
  'form_id': 'form-1',
  'node_id': 'human-node-1',
  'node_title': 'Need Approval',
  'form_content': r'Before {{#$output.reason#}} after',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'reason',
      'default': {'selector': <Object?>[], 'type': 'constant', 'value': 'prefill'},
    },
  ],
  'actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
  ],
  'form_token': 'token-1',
  'resolved_default_values': <String, Object?>{},
  'display_in_ui': true,
  'expiration_time': 2000000000,
  ...o,
};

DifyJson createFilledForm([Map<String, Object?> o = const {}]) => {
  'node_id': 'node-1',
  'node_title': 'Approval',
  'rendered_content': 'Approved by Alice',
  'action_id': 'approve',
  'action_text': 'Approve',
  'submitted_data': {'summary': 'Approved by Alice'},
  ...o,
};

Finder get textarea =>
    find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText));

Future<void> renderList(
  WidgetTester t,
  List<DifyJson> forms, {
  Map<String, DifyJson> nodes = const {},
  HumanInputFormSubmit? onSubmit,
}) => renderRun(
  t,
  SingleChildScrollView(
    child: HumanInputFormList(
      inPanel: true,
      humanInputFormDataList: forms,
      onHumanInputFormSubmit: onSubmit,
      getHumanInputNodeData: (id) => nodes[id],
    ),
  ),
  size: const Size(640, 900),
);

void main() {
  group('HumanInputFormList', () {
    testWidgets('should render only visible forms, derive delivery method tips, and submit updated inputs', (t) async {
      final submits = <(String, DifyJson)>[];
      await renderList(
        t,
        [
          createFormData(),
          createFormData({
            'form_id': 'form-2',
            'node_id': 'human-node-2',
            'node_title': 'Hidden Form',
            'display_in_ui': false,
          }),
        ],
        nodes: {
          'human-node-1': {
            'delivery_methods': [
              {
                'id': 'email-1',
                'type': 'email',
                'enabled': true,
                'config': {
                  'recipients': {'whole_workspace': false, 'items': <Object?>[]},
                  'subject': 'Need approval',
                  'body': 'Please review',
                  'debug_mode': true,
                },
              },
            ],
          },
          'human-node-2': {'delivery_methods': <Object?>[]},
        },
        onSubmit: (token, data) async => submits.add((token, data)),
      );
      final titles = [
        for (final w in t.widgetList<HumanInputContentWrapper>(find.byType(HumanInputContentWrapper))) w.nodeTitle,
      ];
      expect(titles, ['Need Approval']);
      expect(t.widget<EditableText>(textarea).controller.text, 'prefill');
      expect(find.byKey(const Key('expiration-time')), findsOneWidget);
      expect(find.byKey(const Key('tips')), findsOneWidget);
      await t.enterText(textarea, '');
      await t.enterText(textarea, 'updated reason');
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits, hasLength(1));
      expect(submits.single.$1, 'token-1');
      expect(submits.single.$2, {
        'inputs': {'reason': 'updated reason'},
        'action': 'approve',
      });
    });

    testWidgets('should omit delivery tips when the node has no enabled delivery methods', (t) async {
      await renderList(
        t,
        [createFormData()],
        nodes: {
          'human-node-1': {'delivery_methods': <Object?>[]},
        },
      );
      expect(find.byKey(const Key('tips')), findsNothing);
    });

    testWidgets('should reset inputs when the same node produces a new form', (t) async {
      await renderList(t, [createFormData()]);
      await t.enterText(textarea, 'previous response');
      await renderList(t, [
        createFormData({'form_id': 'form-2', 'form_token': 'token-2'}),
      ]);
      expect(t.widget<EditableText>(textarea).controller.text, 'prefill');
    });

    testWidgets('should render an empty container when there are no visible forms', (t) async {
      await renderList(t, const []);
      expect(find.byKey(const Key('content-wrapper')), findsNothing);
    });
  });

  group('HumanInputFilledFormList', () {
    testWidgets('renders submitted form content and toggles expansion', (t) async {
      await renderRun(
        t,
        SingleChildScrollView(
          child: HumanInputFilledFormList(
            inPanel: true,
            first: true,
            humanInputFilledFormDataList: [
              createFilledForm(),
              createFilledForm({
                'node_id': 'node-2',
                'node_title': 'Review',
                'rendered_content': 'Reviewed by Bob',
                'action_id': 'review',
                'action_text': 'Review',
              }),
            ],
          ),
        ),
        size: const Size(640, 900),
      );
      final titles = [
        for (final w in t.widgetList<HumanInputContentWrapper>(find.byType(HumanInputContentWrapper))) w.nodeTitle,
      ];
      expect(titles, ['Approval', 'Review']);
      expect(find.byKey(const Key('submitted-field-values')), findsNWidgets(2));
      expect(find.byKey(const Key('executed-action')), findsNWidgets(2));
      final summaries = find.byKey(const Key('submitted-field-summary'));
      expect(summaries, findsNWidgets(2));
      expect(t.widget<Text>(summaries.first).data, 'Approved by Alice');
      final collapse = find.bySemanticsLabel('share.chat.collapse Approval');
      await t.tap(collapse);
      await t.pump();
      expect(
        t
            .getSemantics(find.bySemanticsLabel('share.chat.expand Approval'))
            .getSemanticsData()
            .flagsCollection
            .isExpanded,
        Tristate.isFalse,
      );
      expect(find.byKey(const Key('submitted-field-values')), findsOneWidget);
    });
  });
}
