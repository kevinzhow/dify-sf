// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/user-action.spec.tsx
//
// Typed text is a draft committed on blur, so each edit is followed by a blur.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

const action = {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'};

void main() {
  late List<Map<String, Object?>> changes;
  late List<String> deletes;
  late Toasts toasts;

  setUp(() {
    changes = [];
    deletes = [];
    toasts = Toasts();
  });

  Widget item({bool readonly = false}) => UserActionItem(
    data: action,
    readonly: readonly,
    onChange: (a, _) => changes.add(a),
    onDelete: deletes.add,
  );

  Finder input(String key) => find.descendant(
    of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == hiKey(key)),
    matching: find.byType(EditableText),
  );

  Future<void> type(WidgetTester t, String key, String text) async {
    await t.enterText(input(key), text);
    await t.pump();
  }

  group('UserActionItem', () {
    testWidgets('should sanitize ids, enforce length limits, and update the button text', (t) async {
      await pumpComponent(t, item(), toasts: toasts);

      await type(t, 'userActions.actionNamePlaceholder', 'Approve action');
      await blur(t);
      await type(t, 'userActions.actionNamePlaceholder', '1invalid');
      await type(t, 'userActions.actionNamePlaceholder', 'averyveryveryverylongidentifier');
      await blur(t);
      await type(t, 'userActions.buttonTextPlaceholder', 'card_visa_enterprise_001');
      await blur(t);

      expect(changes[0]['id'], 'Approve_action');
      expect(changes[1]['id'], 'averyveryveryverylon');
      expect(changes[2]['title'], 'card_visa_enterprise_001');
      expect(toasts.messages, [
        hiKey('userActions.actionIdFormatTip'),
        '${hiKey('userActions.actionIdTooLong')}:{"maxLength":20}',
      ]);
    });

    testWidgets('should support clearing ids, updating button style, deleting, and readonly mode', (t) async {
      await pumpComponent(t, item(), toasts: toasts);

      await type(t, 'userActions.actionNamePlaceholder', '   ');
      await blur(t);
      await tapNamed(t, hiKey('userActions.chooseStyle'));
      await t.tap(find.text('Approve').last);
      await t.pump();
      await tapNamed(t, 'common.operation.delete');

      expect(changes[0]['id'], '');
      expect(changes[1]['button_style'], 'ghost');
      expect(deletes, ['approve']);

      await pumpComponent(t, item(readonly: true));
      expect(t.widget<DifyInput>(find.byType(DifyInput).first).disabled, isTrue);
      expect(t.widget<DifyInput>(find.byType(DifyInput).last).disabled, isTrue);
      expect(named('common.operation.delete'), findsNothing);
    });
  });
}
