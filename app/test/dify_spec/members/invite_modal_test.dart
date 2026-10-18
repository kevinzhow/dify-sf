// dify-spec: web/app/components/header/account-setting/members-page/invite-modal/__tests__/index.spec.tsx
//
// Dify's dialog is controlled by its caller (open / onOpenChange / onSend); dify-sf's is a dialog route opened by
// showInviteModal, which resolves with the results (Dify's onSend after onOpenChange(false)) or null when closed.
import 'dart:async';

import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/members/invite_modal.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _roles = [
  WorkspaceRole(id: 'admin', name: 'Admin', description: 'Can manage workspace settings'),
  WorkspaceRole(id: 'editor', name: 'Editor', description: 'Can build and edit apps'),
];

class _Host {
  final calls = <({List<String> emails, String role})>[];

  /// The next answers, in order (a Completer's future holds the request).
  final answers = <Future<List<InvitationResult>> Function()>[];
  final results = <List<InvitationResult>?>[];
  int opened = 0;

  Future<List<InvitationResult>> send(List<String> emails, String role) {
    calls.add((emails: emails, role: role));
    return answers.isEmpty ? Future.value(const []) : answers.removeAt(0)();
  }
}

Future<_Host> _open(WidgetTester t, {bool isEmailSetup = true, _Host? host}) async {
  final h = host ?? _Host();
  await renderMembers(
    t,
    Builder(
      builder: (context) => Center(
        child: DifyButton(
          key: const ValueKey('open-invite'),
          onPressed: () async {
            h.opened++;
            h.results.add(await showInviteModal(context, send: h.send, isEmailSetup: isEmailSetup, roles: _roles));
          },
          child: const Text('members.invite'),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open-invite')));
  await settle(t);
  return h;
}

Future<void> _selectAdminRole(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('role-selector-trigger')));
  await settle(t, 3);
  await t.tap(find.byKey(const ValueKey('role-option-admin')));
  await settle(t, 3);
}

Future<void> _send(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('send-invite')));
  await settle(t);
}

Finder get _roleTrigger => find.byKey(const ValueKey('role-selector-trigger'));

bool get _dialogOpen => find.text('common.members.inviteTeamMemberTip').evaluate().isNotEmpty;

void main() {
  group('InviteModal', () {
    testWidgets('renders a labeled form inside a controlled dialog', (t) async {
      await _open(t);
      expect(find.semantics.byPredicate((n) => n.label == 'common.members.inviteTeamMember'), findsWidgets);
      expect(find.text('common.members.inviteTeamMemberTip'), findsOneWidget);
      expect(find.byType(InviteForm), findsOneWidget);
      expect(t.widget<TextField>(emailInput).keyboardType, TextInputType.emailAddress);
    });

    testWidgets('should place initial focus in the email composer', (t) async {
      await _open(t);
      expect(emailHasFocus(t), isTrue);
    });

    testWidgets('should focus the email field first when the untouched form is submitted with Enter', (t) async {
      final h = await _open(t);
      expect(emailHasFocus(t), isTrue);
      await press(t, LogicalKeyboardKey.enter);
      expect(emailHasFocus(t), isTrue);
      expect(find.text('common.members.emailRequired'), findsOneWidget);
      expect(h.calls, isEmpty);
    });

    testWidgets('shows the email service warning in the form', (t) async {
      await _open(t, isEmailSetup: false);
      expect(find.text('common.members.emailNotSetup'), findsOneWidget);
    });

    testWidgets('submits normalized, deduplicated recipients with the selected Role id', (t) async {
      final h = await _open(t);
      await pasteText(t, 'First@Example.com, second@example.com; first@example.com');
      await _selectAdminRole(t);
      expect(find.text('common.members.sendInviteCount:{"count":2}'), findsOneWidget);
      await _send(t);
      expect(h.calls.single.emails, ['first@example.com', 'second@example.com']);
      expect(h.calls.single.role, 'admin');
      expect(_dialogOpen, isFalse);
      expect(h.results.single, isEmpty);
    });

    testWidgets('submits a valid draft without requiring Enter or blur to create a chip', (t) async {
      final h = await _open(t);
      await _selectAdminRole(t);
      await typeText(t, 'draft@example.com');
      await _send(t);
      expect(h.calls.single.emails, ['draft@example.com']);
      expect(h.calls.single.role, 'admin');
    });

    testWidgets('should submit a manually typed email list without requiring Enter', (t) async {
      final h = await _open(t);
      await _selectAdminRole(t);
      await typeText(t, 'first@gmail.com,second@gmail.com');
      await _send(t);
      expect(h.calls.single.emails, ['first@gmail.com', 'second@gmail.com']);
    });

    testWidgets('should create exactly one non-empty recipient when a single draft is submitted', (t) async {
      final h = _Host();
      final pending = Completer<List<InvitationResult>>();
      h.answers.add(() => pending.future);
      await _open(t, host: h);
      await _selectAdminRole(t);
      await typeText(t, 'only@gmail.com');
      await _send(t);
      expect(chip('only@gmail.com'), findsOneWidget);
      expect(draftText(t), '');
      pending.complete(const []);
      await settle(t);
    });

    testWidgets('should commit a non-empty draft before Enter submits the form', (t) async {
      final h = await _open(t);
      await _selectAdminRole(t);
      await typeText(t, 'draft@example.com{Enter}');
      expect(chip('draft@example.com'), findsOneWidget);
      expect(draftText(t), '');
      expect(emailHasFocus(t), isTrue);
      expect(h.calls, isEmpty);
      await press(t, LogicalKeyboardKey.enter);
      await settle(t);
      expect(h.calls.single.emails, ['draft@example.com']);
      expect(h.calls.single.role, 'admin');
    });

    testWidgets('accepts an address allowed by the browser without requiring a dotted domain', (t) async {
      final h = await _open(t);
      await typeText(t, 'person@example{Enter}');
      await _selectAdminRole(t);
      await _send(t);
      expect(h.calls.single.emails, ['person@example']);
    });

    testWidgets('keeps invalid recipients visible and blocks the whole submission', (t) async {
      final h = await _open(t);
      await pasteText(t, 'valid@example.com, invalid-email');
      await _selectAdminRole(t);
      await _send(t);
      expect(chip('invalid-email'), findsOneWidget);
      expect(find.text('common.members.emailInvalid'), findsWidgets);
      expect(h.calls, isEmpty);
    });

    testWidgets('should preserve and refocus an invalid draft until the user corrects it', (t) async {
      final h = await _open(t);
      await _selectAdminRole(t);
      await typeText(t, 'not-an-email');
      await _send(t);
      expect(draftText(t), 'not-an-email');
      expect(emailHasFocus(t), isTrue);
      expect(find.text('common.members.emailInvalid'), findsOneWidget);
      expect(h.calls, isEmpty);

      await t.enterText(emailInput, '');
      await typeText(t, 'corrected@example.com');
      await _send(t);
      expect(h.calls.single.emails, ['corrected@example.com']);
    });

    testWidgets('shows the required error and focuses the email field after an empty submission', (t) async {
      final h = await _open(t);
      await _selectAdminRole(t);
      await _send(t);
      expect(find.text('common.members.emailRequired'), findsOneWidget);
      expect(emailHasFocus(t), isTrue);
      expect(h.calls, isEmpty);
    });

    testWidgets('should preserve the email draft while the user resolves a missing role', (t) async {
      final h = await _open(t);
      await typeText(t, 'draft@example.com');
      await _send(t);
      expect(focusIsIn(_roleTrigger), isTrue);
      expect(find.byKey(const ValueKey('role-error')), findsOneWidget);
      expect(draftText(t), 'draft@example.com');
      expect(h.calls, isEmpty);

      await _selectAdminRole(t);
      await _send(t);
      expect(h.calls.single.emails, ['draft@example.com']);
      expect(h.calls.single.role, 'admin');
    });

    testWidgets('freezes all editable controls while invitations are being sent', (t) async {
      final h = _Host();
      final pending = Completer<List<InvitationResult>>();
      h.answers.add(() => pending.future);
      await _open(t, host: h);
      await pasteText(t, 'user@example.com, another@example.com');
      await _selectAdminRole(t);
      await _send(t);
      expect(t.widget<TextField>(emailInput).enabled, isFalse);
      expect(buttonEnabled('common.members.role'), isFalse);
      expect(buttonEnabled('common.operation.remove user@example.com'), isFalse);
      expect(buttonEnabled('common.members.sendInviteCount'), isFalse);
      expect(h.calls, hasLength(1));
      pending.complete(const []);
      await settle(t);
    });

    // Without the seats warning: dify-sf (like Dify's community edition) has no member seat limits.
    testWidgets('counts a manually typed recipient list before it is committed', (t) async {
      await _open(t);
      await typeText(t, 'one@example.com,two@example.com');
      expect(find.text('common.members.sendInviteCount:{"count":2}'), findsOneWidget);
      expect(buttonEnabled('common.members.sendInviteCount'), isTrue);
      expect(chip('one@example.com'), findsNothing);
      expect(draftText(t), 'one@example.com,two@example.com');
    });

    testWidgets('maps %s server validation to the owning field', (t) async {
      for (final (code, message, field) in [
        ('limit_exceeded', 'common.members.inviteLimitExceeded', 'emails'),
        ('invalid_role', 'common.members.invalidRole', 'role'),
      ]) {
        final h = _Host();
        h.answers.add(() => Future.error(TransportException('Backend message', statusCode: 400, code: code)));
        await _open(t, host: h);
        await pasteText(t, 'user@example.com, another@example.com');
        await _selectAdminRole(t);
        await _send(t);
        expect(find.text(message), findsOneWidget, reason: code);
        expect(field == 'emails' ? emailHasFocus(t) : focusIsIn(_roleTrigger), isTrue, reason: code);
        expect(_dialogOpen, isTrue);
        expect(h.results, isEmpty);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('keeps a role server error visible when the user only opens the selector', (t) async {
      final h = _Host();
      h.answers.add(
        () => Future.error(const TransportException('Backend message', statusCode: 400, code: 'invalid_role')),
      );
      await _open(t, host: h);
      await pasteText(t, 'user@example.com');
      await _selectAdminRole(t);
      await _send(t);
      expect(find.text('common.members.invalidRole'), findsOneWidget);

      await t.tap(_roleTrigger);
      await settle(t, 3);
      expect(find.text('common.members.invalidRole'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('role-option-editor')));
      await settle(t, 3);
      expect(find.text('common.members.invalidRole'), findsNothing);
    });

    testWidgets('should clear an email server error when the user edits and successfully retries', (t) async {
      final h = _Host();
      h.answers
        ..add(() => Future.error(const TransportException('Backend message', statusCode: 400, code: 'limit_exceeded')))
        ..add(() => Future.value(const []));
      await _open(t, host: h);
      await pasteText(t, 'first@example.com, second@example.com');
      await _selectAdminRole(t);
      await _send(t);
      expect(find.text('common.members.inviteLimitExceeded'), findsOneWidget);

      await typeText(t, 'third@example.com');
      expect(find.text('common.members.inviteLimitExceeded'), findsNothing);

      await _send(t);
      expect(h.calls, hasLength(2));
      expect(h.calls[1].emails, ['first@example.com', 'second@example.com', 'third@example.com']);
    });

    testWidgets('should clear an email server error when a recipient is removed before retrying', (t) async {
      final h = _Host();
      h.answers
        ..add(() => Future.error(const TransportException('Backend message', statusCode: 400, code: 'limit_exceeded')))
        ..add(() => Future.value(const []));
      await _open(t, host: h);
      await pasteText(t, 'first@example.com, second@example.com');
      await _selectAdminRole(t);
      await _send(t);
      expect(find.text('common.members.inviteLimitExceeded'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('remove-second@example.com')));
      await t.pump();
      expect(find.text('common.members.inviteLimitExceeded'), findsNothing);

      await _send(t);
      expect(h.calls, hasLength(2));
      expect(h.calls[1].emails, ['first@example.com']);
    });

    testWidgets('keeps unknown request failures as a persistent form error', (t) async {
      final h = _Host();
      h.answers.add(() => Future.error(const TransportException('connection refused')));
      await _open(t, host: h);
      await pasteText(t, 'user@example.com, another@example.com');
      await _selectAdminRole(t);
      await _send(t);
      expect(find.byKey(const ValueKey('invite-form-error')), findsOneWidget);
      expect(find.text('common.members.inviteFailed'), findsOneWidget);
      expect(_dialogOpen, isTrue);
    });

    testWidgets('routes close actions through the controlled state owner', (t) async {
      final h = await _open(t);
      await tapButton(t, 'common.operation.close');
      expect(_dialogOpen, isFalse);
      expect(h.results, [null]);
    });

    testWidgets('resets the form after a controlled close', (t) async {
      final h = await _open(t);
      await pasteText(t, 'person@example.com, another@example.com');
      await tapButton(t, 'common.operation.close');
      expect(_dialogOpen, isFalse);

      await t.tap(find.byKey(const ValueKey('open-invite')));
      await settle(t);
      expect(h.opened, 2);
      expect(chip('person@example.com'), findsNothing);
      expect(find.text('common.members.selectRole'), findsOneWidget);
    });
  });
}
