/// web/app/reset-password (Dify 1.17.1), the sign-in page's "Forgot your password?": page.tsx (the email the code goes
/// to), check-code/page.tsx (the six-digit code, with components/signin/countdown.tsx) and set-password/page.tsx (the new
/// password, then "Your password has been successfully changed" and back to the sign-in page), inside
/// reset-password-layout.tsx (the sign-in layout). The set-password page also takes an admin's reset link (dify-sf).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import 'auth_api.dart' show TransportException;
import 'auth_controller.dart';
import 'validation.dart';
import 'widgets/auth_widgets.dart';

/// `t(key, { ns: 'common' })`.
String _tCommon(BuildContext context, String key) {
  AppLocaleScope.of(context);
  return DifyI18n.tr('common', key);
}

/// components/signin/storage.ts `COUNT_DOWN_TIME_MS`.
const resendCountdownMs = 59000;

/// The message Dify's request layer toasts for a refused request.
String _message(Object e) => e is TransportException ? e.message : '$e';

/// The rounded icon box the pages start with (`size-14 rounded-2xl border border-components-panel-border-subtle
/// bg-background-default-dodge shadow-lg`, a 24 px icon).
class _IconBox extends StatelessWidget {
  const _IconBox({required this.child, this.filled = true});
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? DifyColors.backgroundDefaultDodge : null,
        border: Border.all(color: DifyColors.componentsPanelBorderSubtle),
        borderRadius: BorderRadius.circular(16),
        boxShadow: DifyShadows.lg,
      ),
      child: child,
    ),
  );
}

/// `py-2` around a 1 px line fading out at both ends.
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            DifyColors.backgroundGradientMaskTransparent,
            DifyColors.dividerRegular,
            DifyColors.backgroundGradientMaskTransparent,
          ],
        ),
      ),
    ),
  );
}

/// The way back (`flex h-9 items-center justify-center text-text-tertiary hover:text-text-primary`): the arrow in a
/// `rounded-full bg-background-default-dimmed p-1` circle and the label (`ml-2 system-xs-regular`). A link on the email
/// page ("Back to login"), a button on the code page ("Back").
class _BackLink extends StatefulWidget {
  const _BackLink({super.key, required this.label, required this.onTap, this.link = false});
  final String label;
  final VoidCallback onTap;
  final bool link;

  @override
  State<_BackLink> createState() => _BackLinkState();
}

class _BackLinkState extends State<_BackLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? DifyColors.textPrimary : DifyColors.textTertiary;
    return Semantics(
      link: widget.link,
      button: !widget.link,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            height: 36,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: DifyColors.backgroundDefaultDimmed, shape: BoxShape.circle),
                  child: RemixIcon('arrow-left-line', size: 12, color: color),
                ),
                const SizedBox(width: 8),
                Text(widget.label, style: difyTextStyle(DifyType.systemXsRegular, color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- /reset-password ----------------------------------------------------------------------------------------------

/// reset-password/page.tsx in its layout.
class ResetPasswordPage extends StatelessWidget {
  const ResetPasswordPage({super.key, this.route = const ResetPasswordRoute()});
  final ResetPasswordRoute route;

  @override
  Widget build(BuildContext context) => SignInLayout(child: ResetPasswordForm(route: route));
}

/// The lock icon, "Reset Password" with its description, the email (required, Dify's email rule) and "Send Verification
/// Code", which mails the code and goes on to the code page (the resend countdown starts); "Back to login" below.
class ResetPasswordForm extends StatefulWidget {
  const ResetPasswordForm({super.key, this.route = const ResetPasswordRoute()});
  final ResetPasswordRoute route;

  @override
  State<ResetPasswordForm> createState() => _ResetPasswordFormState();
}

class _ResetPasswordFormState extends State<ResetPasswordForm> {
  final _email = AuthField();
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (!submitAuthForm([_email])) return;
    final auth = AuthScope.read(context);
    if (auth == null) return;
    final email = _email.value;
    setState(() => _loading = true);
    try {
      final token = await auth.sendResetCode(email, language: AppLocaleScope.read(context)?.language);
      auth
        ..countdownLeftMs = resendCountdownMs
        ..go(ResetPasswordCheckCodeRoute(email: email, token: token, inviteToken: widget.route.inviteToken));
    } on Object catch (e) {
      if (mounted) toast.error(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _email.validate = (v) {
      if (v.isEmpty) return tLogin(context, 'error.emailEmpty');
      return emailRegex.hasMatch(v) ? null : tLogin(context, 'error.emailInValid');
    };
    final title = tLogin(context, 'resetPassword');
    return DifyDocumentTitle(
      title: title,
      child: AuthSubmitOnEnter(
        onSubmit: _submit,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            _IconBox(
              child: RemixIcon('lock-password-line', size: 24, color: DifyColors.textAccentLightModeOnly),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AuthHeading(title, style: difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary)),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tLogin(context, 'resetPasswordDesc'),
                      style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthTextField(
                  key: const ValueKey('reset-email'),
                  field: _email,
                  label: tLogin(context, 'email'),
                  placeholder: tLogin(context, 'emailPlaceholder'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                DifyButton(
                  key: const ValueKey('reset-send'),
                  variant: DifyButtonVariant.primary,
                  loading: _loading,
                  onPressed: _submit,
                  child: Text(tLogin(context, 'sendVerificationCode')),
                ),
              ],
            ),
            const _Divider(),
            _BackLink(
              key: const ValueKey('reset-back-to-login'),
              label: tLogin(context, 'backToLogin'),
              link: true,
              onTap: () => AuthScope.read(context)?.go(SignInRoute(inviteToken: widget.route.inviteToken)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- /reset-password/check-code -----------------------------------------------------------------------------------

/// reset-password/check-code/page.tsx in its layout.
class ResetPasswordCheckCodePage extends StatelessWidget {
  const ResetPasswordCheckCodePage({super.key, required this.route});
  final ResetPasswordCheckCodeRoute route;

  @override
  Widget build(BuildContext context) => SignInLayout(child: ResetPasswordCheckCodeForm(route: route));
}

/// The mail icon, "Check your email" (the code went to EMAIL, valid for 5 minutes), the code (six digits) and "Verify",
/// which goes on to the new password; the resend countdown; "Back" to the email page.
class ResetPasswordCheckCodeForm extends StatefulWidget {
  const ResetPasswordCheckCodeForm({super.key, required this.route});
  final ResetPasswordCheckCodeRoute route;

  @override
  State<ResetPasswordCheckCodeForm> createState() => _ResetPasswordCheckCodeFormState();
}

class _ResetPasswordCheckCodeFormState extends State<ResetPasswordCheckCodeForm> {
  final _code = AuthField();
  bool _loading = false;
  late String _token = widget.route.token;

  static final _sixDigits = RegExp(r'^[0-9]{6}$');

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_loading) return;
    if (!submitAuthForm([_code])) return;
    final auth = AuthScope.read(context);
    if (auth == null) return;
    final invalid = tLogin(context, 'checkCode.invalidCode');
    setState(() => _loading = true);
    try {
      final r = await auth.checkResetCode(email: widget.route.email, code: _code.value, token: _token);
      if (r.isValid) {
        auth.go(ResetPasswordSetRoute(token: r.token, inviteToken: widget.route.inviteToken));
      } else {
        toast.error(invalid);
      }
    } on Object catch (e) {
      if (mounted) toast.error(_message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    try {
      final token = await auth.sendResetCode(widget.route.email, language: AppLocaleScope.read(context)?.language);
      if (mounted) setState(() => _token = token);
    } on Object catch (e) {
      if (mounted) toast.error(_message(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    _code.validate = (v) {
      if (v.isEmpty) return tLogin(context, 'checkCode.emptyCode');
      return _sixDigits.hasMatch(v) ? null : tLogin(context, 'checkCode.invalidCode');
    };
    final title = tLogin(context, 'checkCode.checkYourEmail');
    final secondary = difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary);
    return DifyDocumentTitle(
      title: title,
      child: AuthSubmitOnEnter(
        onSubmit: _verify,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            _IconBox(
              child: RemixIcon('mail-send-fill', size: 24, color: DifyColors.textAccentLightModeOnly),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AuthHeading(title, style: difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary)),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text.rich(
                      TextSpan(
                        style: secondary,
                        children: [
                          TextSpan(text: tLogin(context, 'checkCode.tipsPrefix')),
                          TextSpan(
                            text: widget.route.email,
                            style: DifyTw.fontBold.style, // `<strong>`
                          ),
                          TextSpan(text: '\n${tLogin(context, 'checkCode.validTime')}'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthTextField(
                  key: const ValueKey('reset-code'),
                  field: _code,
                  label: tLogin(context, 'checkCode.verificationCode'),
                  placeholder: tLogin(context, 'checkCode.verificationCodePlaceholder'),
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 6,
                  onSubmitted: (_) => _verify(),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: DifyButton(
                    key: const ValueKey('reset-verify'),
                    variant: DifyButtonVariant.primary,
                    loading: _loading,
                    onPressed: _verify,
                    child: Text(tLogin(context, 'checkCode.verify')),
                  ),
                ),
                ResendCountdown(onResend: () => unawaited(_resend())),
              ],
            ),
            const _Divider(),
            _BackLink(
              key: const ValueKey('reset-back'),
              label: tLogin(context, 'back'),
              onTap: () => AuthScope.read(context)?.go(ResetPasswordRoute(inviteToken: widget.route.inviteToken)),
            ),
          ],
        ),
      ),
    );
  }
}

/// components/signin/countdown.tsx: "Didn't receive the code? 59s" counting down from the time the code was sent
/// ([AuthController.countdownLeftMs], Dify's `leftTime` in local storage), then the "Resend" button, which restarts it.
class ResendCountdown extends StatefulWidget {
  const ResendCountdown({super.key, this.onResend, this.resendDisabled = false});
  final VoidCallback? onResend;
  final bool resendDisabled;

  @override
  State<ResendCountdown> createState() => _ResendCountdownState();
}

class _ResendCountdownState extends State<ResendCountdown> {
  int _leftMs = resendCountdownMs;
  Timer? _timer;
  AuthController? _auth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_auth == null) {
      _auth = AuthScope.read(context);
      _leftMs = _auth?.countdownLeftMs ?? resendCountdownMs;
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (_leftMs <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _leftMs = _leftMs - 1000 < 0 ? 0 : _leftMs - 1000);
      _auth?.countdownLeftMs = _leftMs <= 0 ? null : _leftMs;
      if (_leftMs <= 0) _timer?.cancel();
    });
  }

  void _resend() {
    setState(() => _leftMs = resendCountdownMs);
    _auth?.countdownLeftMs = resendCountdownMs;
    _start();
    widget.onResend?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tertiary = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          style: tertiary,
          children: [
            TextSpan(text: tLogin(context, 'checkCode.didNotReceiveCode')),
            if (_leftMs > 0) TextSpan(text: '${(_leftMs / 1000).round()}s'),
            if (_leftMs <= 0)
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: AuthLink(
                  key: const ValueKey('reset-resend'),
                  tLogin(context, 'checkCode.resend'),
                  style: difyTextStyle(
                    DifyType.systemXsMedium,
                    widget.resendDisabled ? DifyColors.textDisabled : DifyColors.textAccentSecondary,
                  ),
                  onTap: widget.resendDisabled ? null : _resend,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- /reset-password/set-password ---------------------------------------------------------------------------------

/// reset-password/set-password/page.tsx in its layout.
class ResetPasswordSetPage extends StatelessWidget {
  const ResetPasswordSetPage({super.key, required this.route});
  final ResetPasswordSetRoute route;

  @override
  Widget build(BuildContext context) => SignInLayout(child: SetPasswordForm(route: route));
}

/// ChangePasswordForm: "Set a password", the new password (Dify's rule, shown as a hint until it fails) and its
/// confirmation (revalidated when the password changes), each with the visibility button, and "Set a password". Then
/// the green check, "Your password has been successfully changed" and "Sign in now (5)", which goes back to the
/// sign-in page by itself after 5 seconds (to the invitation when the flow started from one).
class SetPasswordForm extends StatefulWidget {
  const SetPasswordForm({super.key, required this.route, this.autoRedirect = const Duration(seconds: 5)});
  final ResetPasswordSetRoute route;

  /// `AUTO_REDIRECT_TIME`.
  final Duration autoRedirect;

  @override
  State<SetPasswordForm> createState() => _SetPasswordFormState();
}

class _SetPasswordFormState extends State<SetPasswordForm> {
  final _password = AuthField();
  final _confirm = AuthField();
  bool _submitting = false;
  bool _success = false;
  int _leftMs = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _password.addListener(_passwordChanged);
  }

  String _lastPassword = '';

  /// Dify's `onValueChange`: a confirmation already typed is checked again against the new password.
  void _passwordChanged() {
    if (_password.value == _lastPassword) return;
    _lastPassword = _password.value;
    if (_confirm.value.isNotEmpty) _confirm.check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _password
      ..removeListener(_passwordChanged)
      ..dispose();
    _confirm.dispose();
    super.dispose();
  }

  AuthRoute get _signInRoute {
    final invite = widget.route.inviteToken;
    return invite != null && invite.isNotEmpty ? ActivateRoute(invite) : const SignInRoute();
  }

  void _toSignIn() {
    _timer?.cancel();
    AuthScope.read(context)?.go(_signInRoute);
  }

  Future<void> _submit() async {
    if (_submitting || _success) return;
    if (!submitAuthForm([_password, _confirm])) return;
    final auth = AuthScope.read(context);
    if (auth == null) return;
    setState(() => _submitting = true);
    try {
      await auth.resetPassword(
        token: widget.route.token,
        newPassword: _password.value,
        passwordConfirm: _confirm.value,
      );
      if (!mounted) return;
      setState(() {
        _success = true;
        _leftMs = widget.autoRedirect.inMilliseconds;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _leftMs -= 1000);
        if (_leftMs <= 0) _toSignIn();
      });
    } on Object catch (e) {
      if (mounted) toast.error(_message(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _password.validate = (v) {
      if (v.trim().isEmpty) return tLogin(context, 'error.passwordEmpty');
      return validPassword.hasMatch(v) ? null : tLogin(context, 'error.passwordInvalid');
    };
    _confirm.validate = (v) => v.isNotEmpty && v == _password.value ? null : _tCommon(context, 'account.notEqual');
    final title = tLogin(context, _success ? 'passwordChangedTip' : 'changePassword');
    final heading = difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary);
    final Widget body;
    if (_success) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: _IconBox(
              filled: false,
              child: RemixIcon('checkbox-circle-fill', size: 24, color: DifyColors.textSuccess),
            ),
          ),
          AuthHeading(title, style: heading),
          const SizedBox(height: 24),
          DifyButton(
            key: const ValueKey('reset-sign-in-now'),
            variant: DifyButtonVariant.primary,
            onPressed: _toSignIn,
            child: Text('${tLogin(context, 'passwordChanged')} (${(_leftMs / 1000).round()}) '),
          ),
        ],
      );
    } else {
      body = AuthSubmitOnEnter(
        onSubmit: _submit,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthHeading(title, style: heading),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tLogin(context, 'changePasswordTip'),
                style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary),
              ),
            ),
            const SizedBox(height: 24),
            AuthTextField(
              key: const ValueKey('reset-new-password'),
              field: _password,
              label: _tCommon(context, 'account.newPassword'),
              placeholder: tLogin(context, 'passwordPlaceholder'),
              password: true,
              autofillHints: const [AutofillHints.newPassword],
              description: tLogin(context, 'error.passwordInvalid'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
            AuthTextField(
              key: const ValueKey('reset-confirm-password'),
              field: _confirm,
              label: _tCommon(context, 'account.confirmPassword'),
              placeholder: tLogin(context, 'confirmPasswordPlaceholder'),
              password: true,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            DifyButton(
              key: const ValueKey('reset-set-password'),
              variant: DifyButtonVariant.primary,
              loading: _submitting,
              onPressed: _submit,
              child: Text(tLogin(context, 'changePasswordBtn')),
            ),
          ],
        ),
      );
    }
    return DifyDocumentTitle(title: title, child: body);
  }
}
