// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/email-configure-modal.spec.tsx
//
// The real body editor and recipients (the spec mocks them): the workspace recipient is the "All members" switch.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

Map<String, Object?> createEmailConfig([Map<String, Object?> overrides = const {}]) => {
  'recipients': {'whole_workspace': false, 'items': <Object?>[]},
  'subject': 'Original subject',
  'body': '{{#url#}}',
  'debug_mode': false,
  ...overrides,
};

void main() {
  late List<Map<String, Object?>?> results;
  late Toasts toasts;

  setUp(() {
    results = [];
    toasts = Toasts();
  });

  Future<void> open(WidgetTester t, {Map<String, Object?>? config}) async {
    await pumpComponent(
      t,
      Opener<Map<String, Object?>?>(
        results: results,
        open: (c) => showEmailConfigureModal(
          c,
          config: config,
          email: const EmailContext(nodeId: 'n'),
        ),
      ),
      toasts: toasts,
    );
    await tapAndSettle(t, find.text('open'));
  }

  Finder body() => find.descendant(of: find.byType(DifyPromptEditor), matching: find.byType(EditableText));
  Finder allMembers() => find.byWidgetPredicate(
    (w) => w is DifySwitch && (w.semanticLabel ?? '').startsWith(hiKey('deliveryMethod.emailConfigure.allMembers')),
  );
  Future<void> save(WidgetTester t) => tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.save'));

  group('human-input/delivery-method/email-configure-modal', () {
    testWidgets('should save a valid email configuration with updated values', (t) async {
      await open(t, config: createEmailConfig());
      expect(find.textContaining(hiKey('deliveryMethod.emailConfigure.debugModeTip1')), findsOneWidget);

      await t.enterText(inputNamed(hiKey('deliveryMethod.emailConfigure.subject')), 'Budget alert');
      await t.enterText(body(), 'Please review {{#url#}} now');
      await t.tap(allMembers());
      await t.tap(
        find.byWidgetPredicate(
          (w) => w is DifySwitch && w.semanticLabel == hiKey('deliveryMethod.emailConfigure.debugMode'),
        ),
      );
      await t.pump();
      await save(t);

      expect(results.single, {
        'recipients': {'whole_workspace': true, 'items': <Object?>[]},
        'subject': 'Budget alert',
        'body': 'Please review {{#url#}} now',
        'debug_mode': true,
      });
    });

    testWidgets('should validate subject, body, request url placeholder, and recipients before saving', (t) async {
      await open(t);
      await save(t);
      expect(errorsOf(toasts).last, hiKey('deliveryMethod.emailConfigure.subjectRequired'));

      await t.enterText(inputNamed(hiKey('deliveryMethod.emailConfigure.subject')), 'Subject ready');
      await t.enterText(body(), '   ');
      await t.tap(allMembers());
      await t.pump();
      await save(t);
      expect(errorsOf(toasts).last, hiKey('deliveryMethod.emailConfigure.bodyRequired'));

      await t.enterText(body(), 'Missing placeholder');
      await save(t);
      expect(errorsOf(toasts).last, startsWith(hiKey('deliveryMethod.emailConfigure.bodyMustContainRequestURL')));

      await t.enterText(body(), 'Ready {{#url#}}');
      await t.tap(allMembers());
      await t.pump();
      await save(t);
      expect(errorsOf(toasts).last, hiKey('deliveryMethod.emailConfigure.recipientsRequired'));
      expect(results, isEmpty);
    });

    testWidgets('should close from both the icon trigger and the cancel button', (t) async {
      await open(t, config: createEmailConfig());
      await tapAndSettle(t, iconButton('common.operation.close'));
      await tapAndSettle(t, find.text('open'));
      await tapAndSettle(t, find.widgetWithText(DifyButton, 'common.operation.cancel'));

      expect(results, [null, null]);
    });
  });
}
