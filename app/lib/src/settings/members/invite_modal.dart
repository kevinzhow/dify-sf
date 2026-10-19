/// invite-modal/index.tsx: the "Add team member" dialog (recipients, role, the email-service warning, send).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import '../workspace_members.dart';
import 'email_recipients.dart';
import 'email_recipients_field.dart';
import 'role_selector.dart';

/// Sends the invitations (`POST /v1/workspace/members/invite-email`).
typedef InviteSender = Future<List<InvitationResult>> Function(List<String> emails, String role);

/// Opens the InviteModal; resolves with the invitation results once sent (null when closed). Each opening starts
/// with an empty form (Dify resets it after a controlled close).
Future<List<InvitationResult>?> showInviteModal(
  BuildContext context, {
  required InviteSender send,
  bool isEmailSetup = false,
  List<WorkspaceRole>? roles,
}) => showSettingsDialog<List<InvitationResult>>(
  context,
  (context) => InviteModal(send: send, isEmailSetup: isEmailSetup, roles: roles ?? legacyWorkspaceRoles()),
);

/// InviteModal's content: `DialogContent` (`w-120 p-6`) with the title "Add team member" (`text-xl font-semibold`),
/// the tip (`text-sm text-text-tertiary`), the close button (`absolute inset-e-6 top-6`) and the form (`grid gap-5
/// pt-5`). dify-sf has no mail server, so [isEmailSetup] is false and the warning that links must be passed on is
/// shown (Dify without `MAIL_TYPE`). dify-sf has no seat limits (Dify's community edition neither), so there is no
/// seats warning.
class InviteModal extends StatelessWidget {
  const InviteModal({super.key, required this.send, required this.roles, this.isEmailSetup = false});

  final InviteSender send;
  final List<WorkspaceRole> roles;
  final bool isEmailSetup;

  @override
  Widget build(BuildContext context) {
    final title = stc(context, 'members.inviteTeamMember');
    return SettingsDialogContent(
      label: title,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 20,
                        height: 28 / 20,
                        fontWeight: FontWeight.w600,
                        color: DifyColors.textPrimary,
                      ),
                    ),
                    Text(
                      stc(context, 'members.inviteTeamMemberTip'),
                      style: TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textTertiary),
                    ),
                  ],
                ),
              ),
              InviteForm(send: send, roles: roles, isEmailSetup: isEmailSetup),
            ],
          ),
          const PositionedDirectional(top: 0, end: 0, child: SettingsDialogCloseButton()),
        ],
      ),
    );
  }
}

sealed class _SubmissionError {
  const _SubmissionError();
}

final class _FieldErrors extends _SubmissionError {
  const _FieldErrors({this.emails, this.role});
  final String? emails, role;
}

final class _FormError extends _SubmissionError {
  const _FormError(this.message);
  final String message;
}

/// InviteForm: owns the recipients, the draft, the role and the submission error. Submitting (the button, or Enter
/// in the empty draft) validates the fields first (the first invalid one gets focus: no recipient, an invalid one,
/// no role); then the draft joins the recipients and the invitations are sent with every control frozen. On success
/// the dialog closes with the results; `invalid_role` / `limit_exceeded` become the role / emails field's error, any
/// other failure the form's alert.
class InviteForm extends StatefulWidget {
  const InviteForm({super.key, required this.send, required this.roles, this.isEmailSetup = false});

  final InviteSender send;
  final List<WorkspaceRole> roles;
  final bool isEmailSetup;

  @override
  State<InviteForm> createState() => _InviteFormState();
}

class _InviteFormState extends State<InviteForm> {
  final _emailFocus = FocusNode(debugLabel: 'invite emails');
  final _roleFocus = FocusNode(debugLabel: 'invite role');
  List<EmailRecipient> _recipients = const [];
  String _draft = '';
  WorkspaceRole? _role;
  _SubmissionError? _error;
  bool _submitted = false;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    // The dialog's initial focus is the email composer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emailFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _emailFocus.dispose();
    _roleFocus.dispose();
    super.dispose();
  }

  _FieldErrors? get _fieldErrors => _error is _FieldErrors ? _error! as _FieldErrors : null;

  void _clearEmailSubmissionError() {
    final e = _fieldErrors;
    if (e != null && e.emails != null) setState(() => _error = null);
  }

  /// The emails field's error after a submit (Base UI's onSubmit validation, live from then on), else the server's.
  String? _emailError(BuildContext context) =>
      (_submitted ? validateRecipients(context, _recipients, _draft) : null) ?? _fieldErrors?.emails;

  String? _roleError(BuildContext context) =>
      _fieldErrors?.role ?? (_submitted && _role == null ? stc(context, 'members.selectRole') : null);

  Future<void> _submit() async {
    if (_pending) return;
    setState(() => _submitted = true);
    final emailInvalid = validateRecipients(context, _recipients, _draft) != null;
    if (emailInvalid) {
      _emailFocus.requestFocus();
      return;
    }
    if (_role == null) {
      _roleFocus.requestFocus();
      return;
    }
    final effective = mergeEmailRecipients(_recipients, _draft);
    final role = _role!;
    final invalidRole = stc(context, 'members.invalidRole');
    final limitExceeded = stc(context, 'members.inviteLimitExceeded');
    final failed = stc(context, 'members.inviteFailed');
    setState(() {
      _recipients = effective;
      _draft = '';
      _error = null;
      _pending = true;
    });
    try {
      final results = await widget.send([for (final r in effective) r.value], role.id);
      if (!mounted) return;
      Navigator.of(context).pop(results);
    } on Object catch (e) {
      if (!mounted) return;
      final code = inviteErrorCode(e);
      setState(() {
        _pending = false;
        _error = switch (code) {
          'limit_exceeded' => _FieldErrors(emails: limitExceeded),
          'invalid_role' => _FieldErrors(role: invalidRole),
          _ => _FormError(failed),
        };
      });
      // Base UI focuses the field the server's error names.
      if (code == 'limit_exceeded') _emailFocus.requestFocus();
      if (code == 'invalid_role') _roleFocus.requestFocus();
    } finally {
      if (mounted && _pending) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effective = mergeEmailRecipients(_recipients, _draft);
    final valid = effective.where((r) => r.isValid).length;
    final formError = _error is _FormError ? (_error! as _FormError).message : null;
    return Semantics(
      container: true,
      label: stc(context, 'members.inviteTeamMember'),
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            if (!widget.isEmailSetup)
              Container(
                key: const ValueKey('email-not-setup'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DifyColors.stateWarningHover,
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    RemixIcon('error-warning-fill', size: 16, color: DifyColors.textWarning),
                    Expanded(
                      child: Text(
                        stc(context, 'members.emailNotSetup'),
                        style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            EmailRecipientsField(
              recipients: _recipients,
              draft: _draft,
              focusNode: _emailFocus,
              disabled: _pending,
              error: _emailError(context),
              onRecipientsChange: (v) => setState(() => _recipients = v),
              onDraftChange: (v) => setState(() => _draft = v),
              onChange: _clearEmailSubmissionError,
              // A form submits on Enter in its text input (a non-empty draft is committed instead).
              onSubmit: () => unawaited(_submit()),
            ),
            RoleSelector(
              roles: widget.roles,
              value: _role,
              focusNode: _roleFocus,
              disabled: _pending,
              error: _roleError(context),
              onChanged: (r) => setState(() {
                _role = r;
                // Base UI drops a field's external error when its value changes.
                final e = _fieldErrors;
                if (e != null && e.role != null) _error = _FieldErrors(emails: e.emails);
              }),
            ),
            if (formError != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  formError,
                  key: const ValueKey('invite-form-error'),
                  style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textDestructive),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: DifyButton(
                key: const ValueKey('send-invite'),
                variant: DifyButtonVariant.primary,
                loading: _pending,
                onPressed: () => unawaited(_submit()),
                child: Text(
                  valid > 0
                      ? stc(context, 'members.sendInviteCount', {'count': valid})
                      : stc(context, 'members.sendInvite'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
