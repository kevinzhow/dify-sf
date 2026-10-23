// dify-spec: web/app/components/workflow/nodes/human-input/__tests__/panel.spec.tsx
//
// The whole panel over a document (the spec mocks every part): edits land in the node's data.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

import 'package:flutter/material.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'delivery_methods': [
    {'id': 'dm-webapp', 'type': 'webapp', 'enabled': true},
  ],
  'form_content': 'Please review this request',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'review_result',
      'default': {'selector': <Object?>[], 'type': 'constant', 'value': ''},
    },
  ],
  'user_actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
  ],
  'timeout': 3,
  'timeout_unit': 'day',
  ...overrides,
};

void main() {
  late Harness h;
  late Toasts toasts;

  setUp(() => toasts = Toasts());

  Future<void> start(WidgetTester t, Map<String, Object?> data, {bool canEdit = true}) async {
    h = await Harness.start(t, [hiNode(data)]);
    t.view.physicalSize = const Size(1600, 1000);
    await renderPanel(
      t,
      h,
      toasts: toasts,
      options: WorkflowMenuOptionsX(canEdit: canEdit),
      width: 700,
    );
  }

  Map<String, Object?> data() => dataOf(h, 'hi');
  Finder varItem(String name) => find.byWidgetPredicate((w) => w is VarItem && w.name == name);

  group('human-input/panel', () {
    testWidgets('renders editable controls, forwards updates, and toggles preview and output sections', (t) async {
      await start(t, createData());

      expect(iconButton(hiKey('deliveryMethod.title')), findsOneWidget);
      expect(t.widget<FormContent>(find.byType(FormContent)).isExpand, isFalse);
      expect(t.widget<UserActionItem>(find.byType(UserActionItem)).readonly, isFalse);
      expect(varItem('review_result'), findsNothing);
      await tapAndSettle(t, find.text('workflow.nodes.common.outputVars'.toUpperCase()));
      final items = t.widgetList<VarItem>(find.byType(VarItem)).map((v) => '${v.name}:${v.type}:${v.description}');
      expect(items, [
        'review_result:string:Form input value',
        '__action_id:string:Action ID user triggered',
        '__action_value:string:Selected action value',
        '__rendered_content:string:Rendered content',
      ]);

      // Delivery methods.
      await tapAndSettle(t, iconButton(hiKey('deliveryMethod.title')));
      await tapAndSettle(t, find.text(hiKey('deliveryMethod.types.email.title')));
      expect(data()['delivery_methods'], hasLength(2));
      await t.tapAt(const Offset(5, 500));
      await Harness.settle(t);

      // Preview, at the panel's left.
      await tapAndSettle(t, find.widgetWithText(DifyButton, hiKey('formContent.preview')));
      expect(find.byType(FormContentPreview), findsOneWidget);
      final right = t.getTopRight(find.byType(FormContentPreview)).dx;
      expect(right, closeTo(1600 - h.store.panelWidth.value - 8, 0.5));

      // Form content.
      await t.enterText(
        find.descendant(of: find.byType(DifyPromptEditor).first, matching: find.byType(EditableText)),
        'Updated content',
      );
      await blur(t);
      expect(data()['form_content'], 'Updated content');

      // User actions.
      await tapAndSettle(t, iconButton('common.operation.add'));
      expect(data()['user_actions'], [
        {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
        {'id': 'action_2', 'title': 'Button Text 2', 'button_style': 'default'},
      ]);
      await t.enterText(inputNamed(hiKey('userActions.buttonTextPlaceholder')).first, 'Approve updated');
      await blur(t);
      expect((data()['user_actions']! as List).first, {
        'id': 'approve',
        'title': 'Approve updated',
        'button_style': 'primary',
      });
      await tapAndSettle(t, iconButton('common.operation.delete').first);
      expect(data()['user_actions'], [
        {'id': 'action_2', 'title': 'Button Text 2', 'button_style': 'default'},
      ]);

      // Timeout.
      await tapNamed(t, hiKey('timeout.hours'));
      await Harness.settle(t);
      expect((data()['timeout'], data()['timeout_unit']), (3, 'hour'));

      // Close the preview, copy, expand.
      await tapAndSettle(t, iconButton('common.operation.close'));
      expect(find.byType(FormContentPreview), findsNothing);
      await tapNamed(t, 'common.operation.copy');
      expect(h.clipboard, 'Updated content');
      expect(toasts.list.last, (DataToastType.success, 'common.actionMsg.copySuccessfully'));
      await tapNamed(t, 'share.chat.expand');
      await Harness.settle(t);
      expect(t.widget<FormContent>(find.byType(FormContent)).isExpand, isTrue);
      await h.dispose(t);
    });

    testWidgets('renders readonly and empty states without preview or add controls', (t) async {
      await start(t, createData({'user_actions': <Object?>[]}), canEdit: false);

      expect(iconButton(hiKey('deliveryMethod.title')), findsNothing);
      expect(t.widget<FormContent>(find.byType(FormContent)).readonly, isTrue);
      expect(find.text(hiKey('userActions.emptyTip')), findsOneWidget);
      expect(find.widgetWithText(DifyButton, hiKey('formContent.preview')), findsNothing);
      expect(iconButton('common.operation.add'), findsNothing);
      expect(t.widget<TimeoutInput>(find.byType(TimeoutInput)).readonly, isTrue);
      expect(find.byType(FormContentPreview), findsNothing);
      await h.dispose(t);
    });

    testWidgets('renders file outputs with file-aware types', (t) async {
      await start(
        t,
        createData({
          'inputs': [
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
          ],
        }),
      );
      await tapAndSettle(t, find.text('workflow.nodes.common.outputVars'.toUpperCase()));

      expect(t.widget<VarItem>(varItem('attachment')).type, 'file');
      expect(t.widget<VarItem>(varItem('attachments')).type, 'array[file]');
      await h.dispose(t);
    });
  });
}
