// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/single-run-form.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/single_run.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

Map<String, Object?> createFormData([Map<String, Object?> overrides = const {}]) => {
  'form_id': 'form-1',
  'node_id': 'human-1',
  'node_title': 'Review',
  'form_content': 'Please review {{#\$output.review#}}',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'review',
      'default': {'selector': <Object?>[], 'type': 'constant', 'value': 'initial review'},
    },
  ],
  'actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
  ],
  'form_token': 'token',
  'resolved_default_values': <String, Object?>{},
  ...overrides,
};

void main() {
  late List<List<Object?>> submits;

  Future<void> render(WidgetTester t, Map<String, Object?> data, {VoidCallback? onBack}) => pumpComponent(
    t,
    HumanInputRunForm(
      nodeName: 'Review',
      data: data,
      showBackButton: onBack != null,
      onBack: onBack,
      onSubmit: (inputs, action) async => submits.add([inputs, action]),
    ),
  );

  setUp(() => submits = []);

  group('SingleRunForm', () {
    testWidgets('renders the back action as a named button and forwards clicks', (t) async {
      var backs = 0;
      await render(t, createFormData(), onBack: () => backs++);
      await tapNamed(t, hiKey('singleRun.back'));
      expect(backs, 1);
    });

    testWidgets('a refused submission keeps the answer and enables the actions again', (t) async {
      // A closed form or a lost connection: the owner shows the error, and this widget must not stay disabled.
      var calls = 0;
      final errors = <Object>[];
      await pumpComponent(
        t,
        HumanInputRunForm(
          nodeName: 'Review',
          data: createFormData(),
          onSubmit: (inputs, action) async {
            calls++;
            if (calls == 1) throw StateError('the server refused the answer');
          },
          onError: errors.add,
        ),
      );
      await t.enterText(find.byType(EditableText), 'Looks good');
      await t.tap(find.text('Approve'));
      await t.pump();
      // The refusal reached the owner's error hook (its toast), not the zone.
      expect(errors.single, isA<StateError>());
      // The typed answer is still there, and the action can be pressed again.
      expect(find.text('Looks good'), findsOneWidget);
      final button = t.widget<DifyButton>(find.widgetWithText(DifyButton, 'Approve'));
      expect(button.disabled, isFalse, reason: 'a failed submission re-enables the actions');
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(calls, 2, reason: 'the answer can be submitted again');
    });

    testWidgets('busy (the owner has a request out) disables the actions', (t) async {
      await pumpComponent(
        t,
        HumanInputRunForm(nodeName: 'Review', data: createFormData(), busy: true, onSubmit: (_, _) async {}),
      );
      expect(t.widget<DifyButton>(find.widgetWithText(DifyButton, 'Approve')).disabled, isTrue);
    });

    testWidgets('submits the selected action with initialized inputs', (t) async {
      await render(t, createFormData());
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits.single, [
        {'review': 'initial review'},
        'approve',
      ]);
    });

    testWidgets('submits updated paragraph input values', (t) async {
      await render(t, createFormData());
      await t.enterText(find.descendant(of: named('review'), matching: find.byType(EditableText)), 'updated review');
      await t.pump();
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits.single, [
        {'review': 'updated review'},
        'approve',
      ]);
    });

    testWidgets('uses resolved default values for variable paragraph inputs', (t) async {
      await render(
        t,
        createFormData({
          'inputs': [
            {
              'type': 'paragraph',
              'output_variable_name': 'review',
              'default': {
                'selector': ['source', 'answer'],
                'type': 'variable',
                'value': 'fallback review',
              },
            },
          ],
          'resolved_default_values': {'review': 'resolved review'},
        }),
      );
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits.single, [
        {'review': 'resolved review'},
        'approve',
      ]);
    });

    testWidgets('disables submit actions until a select input has a value', (t) async {
      await render(
        t,
        createFormData({
          'form_content': 'Choose {{#\$output.choice#}}',
          'inputs': [
            {
              'type': 'select',
              'output_variable_name': 'choice',
              'option_source': {
                'selector': <Object?>[],
                'type': 'constant',
                'value': ['approve', 'reject'],
              },
            },
          ],
        }),
      );
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits, isEmpty);

      await t.tap(find.byType(DifySelect<String>));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('approve').last);
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits.single, [
        {'choice': 'approve'},
        'approve',
      ]);
    });
  });
}
