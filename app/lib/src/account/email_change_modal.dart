/// account-page/email-change-modal.tsx (Dify 1.17.1): changing the account's email with codes by mail (protocol 1.12,
/// `/v1/account/change-email...`): a code to the current address, then a new address (checked as it is typed), a code
/// to it, and the change, after which Dify signs out.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../auth/auth_api.dart';
import '../auth/auth_controller.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../settings/settings_kit.dart';
import '../workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart' show transSpans;
import '../workflow_editor/panel_fields/controls.dart' show DifyInput;

/// Shows the modal for the signed-in account of [auth]; closing it drops the flow (Dify mounts it afresh).
Future<void> showEmailChangeModal(BuildContext context, AuthController auth) =>
    showSettingsDialog<void>(context, (context) => EmailChangeModal(auth: auth));

/// The steps (`STEP`).
enum EmailChangeStep { start, verifyOrigin, newEmail, verifyNew }

/// email-change-modal.tsx's `emailPattern`.
final emailChangePattern = RegExp(r"^[\w.!#$%&'*+\-/=?^`{|}~]+@(?:[\w-]+\.)+[\w-]{2,}$");

/// EmailChangeModal: `w-105 p-6` with the close icon (`top-5 right-5 p-1.5`, `i-ri-close-line size-5`) and one step:
/// * start: "Change Email", the warning (`body-md-medium text-text-warning`), where the code goes, "Send verification
///   code" (primary) and Cancel;
/// * verifyOrigin / verifyNew: the code (6 characters enable Continue / "Change to ..."), "Didn't receive a code?" with
///   the 60 s countdown, then Resend;
/// * newEmail: the new address, checked 500 ms after typing (`check-email-unique`: taken or unavailable addresses are
///   named and block sending).
/// Errors toast Dify's texts ("Error sending verification code: ..."). After the change the session ends (Dify's
/// logout): [onChanged] (the session's sign-out by default).
class EmailChangeModal extends StatefulWidget {
  const EmailChangeModal({
    super.key,
    required this.auth,
    this.onChanged,
    this.checkDelay = const Duration(milliseconds: 500),
  });

  final AuthController auth;
  final Future<void> Function()? onChanged;

  /// The debounce of the uniqueness check (`useDebounceFn(..., { wait: 500 })`).
  final Duration checkDelay;

  @override
  State<EmailChangeModal> createState() => _EmailChangeModalState();
}

class _EmailChangeModalState extends State<EmailChangeModal> {
  EmailChangeStep _step = EmailChangeStep.start;
  String _code = '', _mail = '', _stepToken = '';
  int _time = 0;
  bool _exists = false, _unavailable = false, _checking = false;
  Timer? _timer, _debounce;
  String _latest = '';
  int _codeField = 0;

  AuthSession get _session => widget.auth.session;
  String get _email => widget.auth.account?.email ?? '';
  String _c(String key, [Map<String, Object?> params = const {}]) => stc(context, key, params);
  String _message(Object e) => e is TransportException ? e.message : '$e';

  @override
  void dispose() {
    _timer?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _startCount() {
    _timer?.cancel();
    setState(() => _time = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _time = _time <= 1 ? 0 : _time - 1);
      if (_time == 0) t.cancel();
    });
  }

  Future<void> _send(String email, {required bool origin, String? token}) async {
    try {
      final data = await _session.sendChangeEmailCode(
        email: email,
        phase: origin ? 'old_email' : 'new_email',
        token: token,
      );
      if (!mounted) return;
      _startCount();
      if (data.isNotEmpty) setState(() => _stepToken = data);
    } on Object catch (e) {
      toast.error('Error sending verification code: ${_message(e)}');
    }
  }

  Future<void> _verify(String email, String code, String token, void Function(String token) next) async {
    try {
      final res = await _session.checkChangeEmailCode(email: email, code: code, token: token);
      if (!mounted) return;
      if (res.isValid) {
        setState(() => _stepToken = res.token);
        next(res.token);
      } else {
        toast.error('Verifying email failed');
      }
    } on Object catch (e) {
      toast.error('Error verifying email: ${_message(e)}');
    }
  }

  void _setCode(String v) => setState(() => _code = v);

  void _clearCode() => setState(() {
    _code = '';
    _codeField++;
  });

  Future<void> _sendToOrigin() async {
    await _send(_email, origin: true);
    if (mounted) setState(() => _step = EmailChangeStep.verifyOrigin);
  }

  Future<void> _verifyOrigin() async {
    await _verify(_email, _code, _stepToken, (_) => setState(() => _step = EmailChangeStep.newEmail));
    if (mounted) _clearCode();
  }

  Future<void> _checkExists(String email) async {
    setState(() => _checking = true);
    try {
      await _session.checkEmailUnique(email);
      if (!mounted || _latest != email) return;
      setState(() {
        _exists = false;
        _unavailable = false;
      });
    } on TransportException catch (e) {
      if (!mounted || _latest != email) return;
      if (e.statusCode == 400) {
        setState(() {
          if (e.code == 'email_already_in_use') _exists = true;
          if (e.code == 'account_in_freeze') _unavailable = true;
        });
      }
    } on Object {
      // Dify ignores other failures.
    } finally {
      if (mounted && _latest == email) setState(() => _checking = false);
    }
  }

  void _mailChanged(String value) {
    final normalized = value.trim();
    _latest = normalized;
    setState(() {
      _mail = value;
      _exists = false;
      _unavailable = false;
    });
    _debounce?.cancel();
    if (emailChangePattern.hasMatch(normalized)) {
      setState(() => _checking = true);
      _debounce = Timer(widget.checkDelay, () => unawaited(_checkExists(normalized)));
      return;
    }
    setState(() => _checking = false);
  }

  Future<void> _sendToNew() async {
    final normalized = _mail.trim();
    if (!emailChangePattern.hasMatch(normalized)) {
      toast.error('Invalid email format');
      return;
    }
    await _send(normalized, origin: false, token: _stepToken);
    if (mounted) setState(() => _step = EmailChangeStep.verifyNew);
  }

  Future<void> _update(String lastToken) async {
    try {
      await _session.changeEmail(newEmail: _mail.trim(), token: lastToken);
      if (!mounted) return;
      final done = widget.onChanged ?? widget.auth.signOut;
      Navigator.of(context).pop();
      await done();
    } on Object catch (e) {
      toast.error('Error changing email: ${_message(e)}');
    }
  }

  Future<void> _submitNew() => _verify(_mail.trim(), _code, _stepToken, (t) => unawaited(_update(t)));

  // ---- the view ----------------------------------------------------------------------------------------------------

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Semantics(
      header: true,
      child: Text(text, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
    ),
  );

  Widget _withEmail(String key, String email) => Text.rich(
    TextSpan(
      style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary),
      children: transSpans(_c(key, {'email': email}), {
        'email': (inner) => TextSpan(text: inner, style: difyTextStyle(DifyType.bodyMdMedium, DifyColors.textPrimary)),
      }),
    ),
  );

  Widget _intro(List<Widget> lines) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 2, children: lines),
  );

  Widget _label(String text) => Container(
    height: 24,
    margin: const EdgeInsets.only(bottom: 4),
    alignment: AlignmentDirectional.centerStart,
    child: Text(text, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
  );

  Widget _actions({required String primary, Key? primaryKey, required bool enabled, required VoidCallback onPrimary}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          DifyButton(
            key: primaryKey,
            semanticLabel: primary,
            variant: DifyButtonVariant.primary,
            disabled: !enabled,
            onPressed: onPrimary,
            child: Text(primary),
          ),
          DifyButton(
            key: const ValueKey('email-change-cancel'),
            semanticLabel: _c('operation.cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_c('operation.cancel')),
          ),
        ],
      );

  Widget _codeInput() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(_c('account.changeEmail.codeLabel')),
        DifyInput(
          key: ValueKey('email-change-code-$_codeField'),
          semanticLabel: _c('account.changeEmail.codeLabel'),
          placeholder: _c('account.changeEmail.codePlaceholder'),
          value: _code,
          maxLength: 6,
          onChanged: _setCode,
        ),
      ],
    ),
  );

  Widget _resend(VoidCallback resend) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        Text(
          _c('account.changeEmail.resendTip'),
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
        ),
        if (_time > 0)
          Text(
            _c('account.changeEmail.resendCount', {'count': _time}),
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          )
        else
          DifyPressable(
            key: const ValueKey('email-change-resend'),
            semanticLabel: _c('account.changeEmail.resend'),
            onPressed: resend,
            builder: (context, hovered, focused) => Text(
              _c('account.changeEmail.resend'),
              style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccentSecondary),
            ),
          ),
      ],
    ),
  );

  List<Widget> _body() {
    switch (_step) {
      case EmailChangeStep.start:
        return [
          _heading(_c('account.changeEmail.title')),
          _intro([
            Text(
              _c('account.changeEmail.authTip'),
              style: difyTextStyle(DifyType.bodyMdMedium, DifyColors.textWarning),
            ),
            _withEmail('account.changeEmail.content1', _email),
          ]),
          const SizedBox(height: 12),
          _actions(
            primary: _c('account.changeEmail.sendVerifyCode'),
            primaryKey: const ValueKey('email-change-send-origin'),
            enabled: true,
            onPrimary: () => unawaited(_sendToOrigin()),
          ),
        ];
      case EmailChangeStep.verifyOrigin:
        return [
          _heading(_c('account.changeEmail.verifyEmail')),
          _intro([_withEmail('account.changeEmail.content2', _email)]),
          _codeInput(),
          const SizedBox(height: 12),
          _actions(
            primary: _c('account.changeEmail.continue'),
            primaryKey: const ValueKey('email-change-continue'),
            enabled: _code.length == 6,
            onPrimary: () => unawaited(_verifyOrigin()),
          ),
          _resend(() => unawaited(_sendToOrigin())),
        ];
      case EmailChangeStep.newEmail:
        final normalized = _mail.trim();
        final blocked =
            normalized.isEmpty || _exists || _unavailable || _checking || !emailChangePattern.hasMatch(normalized);
        return [
          _heading(_c('account.changeEmail.newEmail')),
          _intro([
            Text(
              _c('account.changeEmail.content3'),
              style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label(_c('account.changeEmail.emailLabel')),
                DifyInput(
                  key: const ValueKey('email-change-new-email'),
                  semanticLabel: _c('account.changeEmail.emailLabel'),
                  placeholder: _c('account.changeEmail.emailPlaceholder'),
                  value: _mail,
                  invalid: _exists || _unavailable,
                  keyboardType: TextInputType.emailAddress,
                  onChanged: _mailChanged,
                ),
                if (_exists || _unavailable)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _c(_exists ? 'account.changeEmail.existingEmail' : 'account.changeEmail.unAvailableEmail'),
                        style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textDestructive),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _actions(
            primary: _c('account.changeEmail.sendVerifyCode'),
            primaryKey: const ValueKey('email-change-send-new'),
            enabled: !blocked,
            onPrimary: () => unawaited(_sendToNew()),
          ),
        ];
      case EmailChangeStep.verifyNew:
        return [
          _heading(_c('account.changeEmail.verifyNew')),
          _intro([_withEmail('account.changeEmail.content4', _mail)]),
          _codeInput(),
          const SizedBox(height: 12),
          _actions(
            primary: _c('account.changeEmail.changeTo', {'email': _mail}),
            primaryKey: const ValueKey('email-change-submit'),
            enabled: _code.length == 6,
            onPrimary: () => unawaited(_submitNew()),
          ),
          _resend(() => unawaited(_sendToNew())),
        ];
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDialogContent(
    label: _c('account.changeEmail.title'),
    width: 420,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: _body()),
        Positioned(
          top: -8,
          right: -8,
          // `p-1.5` around `i-ri-close-line size-5`: an `xl` icon button (36 px, 8 px padding, 20 px icon).
          child: DifyIconButton(
            key: const ValueKey('email-change-close'),
            label: _c('operation.close'),
            size: DifyIconButtonSize.xl,
            icon: RemixIcon('close-line', size: 20, color: DifyColors.textTertiary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    ),
  );
}
