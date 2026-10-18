// dify-spec: web/app/components/header/account-setting/members-page/invite-modal/__tests__/email-recipients-field.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/members/email_recipients.dart';
import 'package:dify_sf_app/src/settings/members/email_recipients_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

class _Wrapper extends StatefulWidget {
  const _Wrapper({this.disabled = false});
  final bool disabled;

  @override
  State<_Wrapper> createState() => _WrapperState();
}

class _WrapperState extends State<_Wrapper> {
  List<EmailRecipient> recipients = const [];
  String draft = '';

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmailRecipientsField(
            recipients: recipients,
            draft: draft,
            disabled: widget.disabled,
            onRecipientsChange: (v) => setState(() => recipients = v),
            onDraftChange: (v) => setState(() => draft = v),
          ),
          DifyButton(key: const ValueKey('next-control'), onPressed: () {}, child: const Text('Next control')),
        ],
      ),
    ),
  );
}

Future<void> _render(WidgetTester t, {bool disabled = false}) => renderMembers(t, _Wrapper(disabled: disabled));

int _chipCount() => find
    .byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('recipient-'),
    )
    .evaluate()
    .length;

bool _nextHasFocus(WidgetTester t) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final next = find.byKey(const ValueKey('next-control')).evaluate().single;
  var inside = focused == next;
  focused.visitAncestorElements((e) {
    if (e == next) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  group('EmailRecipientsField', () {
    testWidgets('describes how to add multiple email addresses', (t) async {
      await _render(t);
      expect(t.widget<TextField>(emailInput).keyboardType, TextInputType.emailAddress);
      final node = find.semantics.byPredicate(
        (n) => n.getSemanticsData().flagsCollection.isTextField && n.label.contains('common.members.emailRecipients'),
      );
      expect(node, findsOneWidget);
      expect(node.evaluate().single.getSemanticsData().hint, contains('common.members.emailRecipientsTip'));
    });

    testWidgets('keeps an uncommitted draft when focus leaves the composer', (t) async {
      await _render(t);
      await typeText(t, 'draft@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(draftText(t), 'draft@example.com');
      expect(_chipCount(), 0);
      expect(_nextHasFocus(t), isTrue);
    });

    testWidgets('should keep a single pasted address in the draft for further editing', (t) async {
      await _render(t);
      await focusEmail(t);
      await pasteText(t, 'Person@Example.com');
      expect(draftText(t), 'Person@Example.com');
      expect(emailHasFocus(t), isTrue);
      expect(_chipCount(), 0);
    });

    testWidgets('commits a valid draft with Enter and keeps focus in the composer', (t) async {
      await _render(t);
      await typeText(t, 'person@example{Enter}');
      expect(chip('person@example'), findsOneWidget);
      expect(draftText(t), '');
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('keeps a manually entered invalid address in the input for correction', (t) async {
      await _render(t);
      await typeText(t, 'not-an-email{Enter}');
      expect(draftText(t), 'not-an-email');
      expect(emailHasFocus(t), isTrue);
      expect(_chipCount(), 0);
      expect(find.text('common.members.emailInvalid'), findsOneWidget);
    });

    testWidgets('does not commit or submit Enter while an IME composition is active', (t) async {
      await _render(t);
      await typeText(t, 'person@example.com');
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'person@example.com',
          selection: TextSelection.collapsed(offset: 18),
          composing: TextRange(start: 10, end: 18),
        ),
      );
      await t.pump();
      final handled = await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(handled, isTrue); // defaultPrevented
      expect(draftText(t), 'person@example.com');
      expect(_chipCount(), 0);
    });

    testWidgets('should wait for Enter before committing manually typed separators', (t) async {
      await _render(t);
      await typeText(t, 'first@example.com,second@example.com;third@example.com');
      expect(_chipCount(), 0);
      await press(t, LogicalKeyboardKey.enter);
      expect(_chipCount(), 3);
      expect(draftText(t), '');
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('should not report a valid delimited draft as invalid when focus leaves', (t) async {
      await _render(t);
      await typeText(t, 'first@example.com,second@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(draftText(t), 'first@example.com,second@example.com');
      expect(find.text('common.members.emailInvalid'), findsNothing);
    });

    testWidgets('should not split manually typed addresses on spaces', (t) async {
      await _render(t);
      await typeText(t, 'first@example.com second@example.com{Enter}');
      expect(draftText(t), 'first@example.com second@example.com');
      expect(emailHasFocus(t), isTrue);
      expect(_chipCount(), 0);
      expect(find.text('common.members.emailInvalid'), findsOneWidget);
    });

    testWidgets('parses batch paste delimiters and removes duplicates case-insensitively', (t) async {
      await _render(t);
      await pasteText(
        t,
        'First@Example.com, second@example.com; FIRST@example.com\nthird@example.com\tfourth@example.com',
      );
      expect(_chipCount(), 4);
      for (final e in ['first@example.com', 'second@example.com', 'third@example.com', 'fourth@example.com']) {
        expect(chip(e), findsOneWidget);
      }
    });

    testWidgets('should combine a batch paste with the draft at the current caret', (t) async {
      await _render(t);
      await typeText(t, 'first@example.com');
      await pasteText(t, ', second@example.com');
      expect(_chipCount(), 2);
      expect(chip('first@example.com'), findsOneWidget);
      expect(chip('second@example.com'), findsOneWidget);
      expect(draftText(t), '');
    });

    testWidgets('should replace a selected draft when a batch is pasted', (t) async {
      await _render(t);
      await typeText(t, 'stale@example.com');
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'stale@example.com',
          selection: TextSelection(baseOffset: 0, extentOffset: 17),
        ),
      );
      await t.pump();
      await pasteText(t, 'first@example.com, second@example.com');
      expect(_chipCount(), 2);
      expect(chip('first@example.com'), findsOneWidget);
      expect(chip('second@example.com'), findsOneWidget);
      expect(chip('stale@example.com'), findsNothing);
      expect(draftText(t), '');
    });

    testWidgets('should deduplicate a later batch against existing recipients', (t) async {
      await _render(t);
      await pasteText(t, 'first@example.com,');
      await pasteText(t, 'FIRST@example.com, second@example.com');
      expect(_chipCount(), 2);
      expect(chip('first@example.com'), findsOneWidget);
      expect(chip('second@example.com'), findsOneWidget);
    });

    testWidgets('moves an invalid pasted address back into the input for editing', (t) async {
      await _render(t);
      await pasteText(t, 'valid@example.com, not-an-email');
      await tapButton(t, 'common.operation.edit not-an-email');
      expect(chip('not-an-email'), findsNothing);
      expect(draftText(t), 'not-an-email');
      expect(emailHasFocus(t), isTrue);
      expect(chip('valid@example.com'), findsOneWidget);
    });

    testWidgets('preserves the draft and restores input focus when a recipient is removed', (t) async {
      await _render(t);
      await typeText(t, 'existing@example.com{Enter}draft@example.com');
      await t.tap(find.byKey(const ValueKey('remove-existing@example.com')));
      await t.pump();
      expect(chip('existing@example.com'), findsNothing);
      expect(draftText(t), 'draft@example.com');
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('supports one keyboard path through chips without adding tab stops', (t) async {
      await _render(t);
      await pasteText(t, 'first@example.com, second@example.com');

      await press(t, LogicalKeyboardKey.arrowLeft);
      expect(chipHasFocus(t, 'second@example.com'), isTrue);
      await press(t, LogicalKeyboardKey.arrowLeft);
      expect(chipHasFocus(t, 'first@example.com'), isTrue);

      await press(t, LogicalKeyboardKey.arrowRight);
      await press(t, LogicalKeyboardKey.delete);
      await t.pump();
      expect(chip('second@example.com'), findsNothing);
      expect(chipHasFocus(t, 'first@example.com'), isTrue);

      await press(t, LogicalKeyboardKey.backspace);
      await t.pump();
      expect(chip('first@example.com'), findsNothing);
      expect(emailHasFocus(t), isTrue);

      await typeText(t, 'last@example.com{Enter}');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(_nextHasFocus(t), isTrue);
    });

    testWidgets('should return focus to the input after moving past the last chip', (t) async {
      await _render(t);
      await pasteText(t, 'first@example.com, second@example.com');
      await press(t, LogicalKeyboardKey.arrowLeft);
      await press(t, LogicalKeyboardKey.arrowRight);
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('should focus the next chip after deleting a middle chip', (t) async {
      await _render(t);
      await pasteText(t, 'first@example.com, second@example.com, third@example.com');
      await press(t, LogicalKeyboardKey.arrowLeft);
      await press(t, LogicalKeyboardKey.arrowLeft);
      await press(t, LogicalKeyboardKey.delete);
      await t.pump();
      expect(chip('second@example.com'), findsNothing);
      expect(chipHasFocus(t, 'third@example.com'), isTrue);
    });

    testWidgets('should return focus to the input when a valid chip is activated with %j', (t) async {
      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
        await _render(t);
        await pasteText(t, 'person@example.com,');
        await press(t, LogicalKeyboardKey.arrowLeft);
        await press(t, key);
        expect(chip('person@example.com'), findsOneWidget);
        expect(emailHasFocus(t), isTrue);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('should move an invalid chip into the focused input when activated from the keyboard', (t) async {
      await _render(t);
      await pasteText(t, 'valid@example.com, not-an-email');
      await press(t, LogicalKeyboardKey.arrowLeft);
      await press(t, LogicalKeyboardKey.enter);
      await t.pump();
      expect(chip('not-an-email'), findsNothing);
      expect(draftText(t), 'not-an-email');
      expect(emailHasFocus(t), isTrue);
      expect(chip('valid@example.com'), findsOneWidget);
    });

    testWidgets('immediately removes the last chip with Backspace from an empty input', (t) async {
      await _render(t);
      await typeText(t, 'person@example.com{Enter}{Backspace}');
      expect(chip('person@example.com'), findsNothing);
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('disables every editing action while the composer is frozen', (t) async {
      await _render(t, disabled: true);
      expect(t.widget<TextField>(emailInput).enabled, isFalse);
    });
  });
}
