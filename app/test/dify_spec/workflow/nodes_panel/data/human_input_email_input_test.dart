// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/recipient/__tests__/email-input.spec.tsx
//
// The real chips and member list (the spec mocks them).
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<String> selects, adds;
  late List<Map<String, Object?>> deletes;

  setUp(() {
    selects = [];
    adds = [];
    deletes = [];
  });

  Widget input(List<Object?> value, {bool disabled = false, List<HiMember> list = members}) => EmailInput(
    email: 'owner@example.com',
    value: value,
    list: list,
    disabled: disabled,
    onDelete: deletes.add,
    onSelect: selects.add,
    onAdd: adds.add,
  );

  Finder field() => find.descendant(of: find.byKey(const ValueKey('email-input')), matching: find.byType(EditableText));
  String? hint(WidgetTester t) =>
      t.widget<DifyTextField>(find.byKey(const ValueKey('email-input'))).decoration.hintText;
  const external = {'type': 'external', 'email': 'existing@example.com'};

  group('human-input/delivery-method/recipient/email-input', () {
    testWidgets('should map selected members, show the placeholder on focus, and select a member from the list', (
      t,
    ) async {
      await pumpComponent(
        t,
        input(const [
          {'type': 'member', 'user_id': 'member-1'},
        ]),
      );
      final chip = t.widget<EmailItem>(find.byType(EmailItem));
      expect((chip.address, chip.name, chip.isError), ('member-1@example.com', 'Member One', false));
      expect(hint(t), '');

      await t.tap(find.byKey(const ValueKey('email-input-box')));
      await t.pump();
      expect(hint(t), hiKey('deliveryMethod.emailConfigure.memberSelector.placeholder'));

      await t.enterText(field(), 'member');
      await t.pump();
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(MemberList), findsOneWidget);
      await t.tap(find.text('Member Two'));
      await t.pump();
      expect(selects, ['member-2']);
    });

    testWidgets('should add external emails, select existing members, and ignore invalid or duplicate values', (
      t,
    ) async {
      await pumpComponent(t, input(const [external]));
      await t.tap(find.byKey(const ValueKey('email-input-box')));
      await t.pump();

      await t.enterText(field(), 'member-2@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.comma);
      await t.pump();
      expect(selects, ['member-2']);

      await t.enterText(field(), 'new@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(adds, ['new@example.com']);

      await t.enterText(field(), 'existing@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();

      await t.tap(find.byKey(const ValueKey('email-input-box')));
      await t.enterText(field(), 'bad-email');
      await blur(t);

      expect(adds, hasLength(1));
      expect(selects, hasLength(1));
    });

    testWidgets('should allow Tab to leave "\$value" and add a valid email only once', (t) async {
      for (final (value, expectedAdds) in const [
        ('', 0),
        ('bad-email', 0),
        ('existing@example.com', 0),
        ('new@example.com', 1),
      ]) {
        adds = [];
        await pumpComponent(
          t,
          Column(
            children: [
              input(const [external]),
              DifyButton(onPressed: () {}, child: const Text('Save')),
            ],
          ),
        );
        await t.tap(field());
        await t.pump();
        if (value.isNotEmpty) await t.enterText(field(), value);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();

        expect(
          focusIn(t, find.widgetWithText(DifyButton, 'Save')),
          isTrue,
          reason:
              'value=$value; primary=${FocusManager.instance.primaryFocus}; chain=${FocusManager.instance.primaryFocus?.ancestors.map((n) => n.debugLabel).toList()}',
        );
        expect(adds, hasLength(expectedAdds));
        if (expectedAdds > 0) expect(adds, [value]);
      }
    });

    testWidgets('should allow Shift+Tab to return to the previous control', (t) async {
      await pumpComponent(
        t,
        Column(
          children: [
            DifyButton(onPressed: () {}, child: const Text('Previous')),
            input(const []),
          ],
        ),
      );
      await t.tap(field());
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(focusIn(t, find.widgetWithText(DifyButton, 'Previous')), isTrue);
    });

    testWidgets('should keep typing focused and stop keyboard events from reaching workflow listeners', (t) async {
      var parentKeys = 0;
      await pumpComponent(
        t,
        Focus(
          onKeyEvent: (_, _) {
            parentKeys++;
            return KeyEventResult.ignored;
          },
          child: input(const []),
        ),
      );
      await t.tap(field());
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
      await t.pump();

      expect(focusIn(t, find.byKey(const ValueKey('email-input'))), isTrue);
      expect(parentKeys, 0);
    });

    testWidgets(
      'should delete the last recipient with backspace, flag missing members as errors, and stop focusing when disabled',
      (t) async {
        await pumpComponent(
          t,
          input(const [
            {'type': 'member', 'user_id': 'missing-member'},
          ]),
        );
        expect(t.widget<EmailItem>(find.byType(EmailItem)).isError, isTrue);
        expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'error-warning-fill'), findsOneWidget);

        await t.tap(field());
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.backspace);
        await t.pump();
        expect(deletes, [
          {'type': 'member', 'user_id': 'missing-member'},
        ]);

        await pumpComponent(t, input(const [], disabled: true));
        await t.tap(find.byKey(const ValueKey('email-input-box')));
        await t.pump();
        expect(find.byKey(const ValueKey('email-input')), findsNothing);
      },
    );
  });
}
