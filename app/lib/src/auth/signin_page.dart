/// web/app/signin (Dify 1.17.1) with email + password as the only sign-in method: normal-form.tsx and
/// components/mail-and-password-auth.tsx as Dify renders them when email codes, SSO and social login are off, sign-up
/// is not allowed, mail is not set up (the "Forgot your password?" link is disabled) and branding is off (community
/// edition: the terms line, the install hint and the copyright show).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import 'auth_api.dart';
import 'auth_controller.dart';
import 'validation.dart';
import 'widgets/auth_widgets.dart';

/// normal-form.tsx inside signin/layout.tsx.
class SignInPage extends StatelessWidget {
  const SignInPage({super.key, this.route = const SignInRoute()});
  final SignInRoute route;

  @override
  Widget build(BuildContext context) => SignInLayout(child: NormalForm(route: route));
}

/// The heading (sign-in or "Join {workspace}"), the email + password form, and the notes below it. A signed-in visitor
/// goes home; on an invitation link, one signed in with the invited email goes on to the invitation's settings.
class NormalForm extends StatefulWidget {
  const NormalForm({super.key, required this.route});
  final SignInRoute route;

  @override
  State<NormalForm> createState() => _NormalFormState();
}

class _NormalFormState extends State<NormalForm> {
  InvitationCheck? _invite;
  bool _inviteLoading = false;
  bool _inviteError = false;

  SignInRoute get route => widget.route;

  @override
  void initState() {
    super.initState();
    if (route.isInvite) unawaited(_checkInvite());
    WidgetsBinding.instance.addPostFrameCallback((_) => _redirectSignedIn());
  }

  Future<void> _checkInvite() async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    setState(() => _inviteLoading = true);
    try {
      final r = await auth.checkInvitation(route.inviteToken!);
      if (!mounted) return;
      setState(() {
        _invite = r;
        _inviteError = !r.isValid;
      });
      _redirectSignedIn();
    } on Object {
      if (mounted) setState(() => _inviteError = true);
    } finally {
      if (mounted) setState(() => _inviteLoading = false);
    }
  }

  /// Dify's effect: a signed-in visitor without an invitation goes to the console home; with one, only when the
  /// invitation is for the signed-in account (emails compared case-insensitively) it goes to invite-settings.
  void _redirectSignedIn() {
    final auth = AuthScope.read(context);
    if (!mounted || auth == null || !auth.signedIn) return;
    if (!route.isInvite) return auth.go(const HomeRoute());
    if (isInvitationForAccount(_invite?.email, auth.account?.email)) auth.go(InviteSettingsRoute(route.inviteToken!));
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final forCurrent = isInvitationForAccount(_invite?.email, auth.account?.email);
    final redirecting = auth.signedIn && (!route.isInvite || forCurrent);
    if (redirecting || (route.isInvite && _inviteLoading)) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: DifyAreaLoading());
    }
    final workspace = _invite?.workspaceName ?? '';
    final tertiaryXs = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    final linkXs = difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthHeading(
            route.isInvite ? '${tLogin(context, 'join')}$workspace' : tLogin(context, 'pageTitle'),
            style: difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              route.isInvite
                  ? '${tLogin(context, 'joinTipStart')}$workspace${tLogin(context, 'joinTipEnd')}'
                  : tLogin(context, 'welcome'),
              style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textTertiary),
            ),
          ),
          // `mt-6 flex flex-col gap-3`: the social and SSO buttons' place, empty here.
          const SizedBox(height: 24),
          if (!_inviteError) ...[
            MailAndPasswordAuth(route: route, invite: _invite),
            // split.tsx `mt-4 mb-5`: a 1 px gradient line, transparent at both ends. CSS collapses its margins with
            // the button's `mb-2` above and the terms line's `mt-2` below: 16 and 20 px in all.
            Container(
              height: 1,
              margin: const EdgeInsets.only(top: 16 - 8, bottom: 20 - 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0x03FFFFFF), Color(0x14101828), Color(0x03FFFFFF)],
                  stops: [0, 0.505, 1],
                ),
              ),
            ),
          ] else
            const _NoLoginMethod(),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AuthInlineLinks(
              style: tertiaryXs,
              spans: [
                '${tLogin(context, 'tosDesc')} ',
                AuthSpanLink(
                  tLogin(context, 'tos'),
                  style: linkXs,
                  url: 'https://dify.ai/terms',
                  hoverUnderline: true,
                ),
                ' & ',
                AuthSpanLink(
                  tLogin(context, 'pp'),
                  style: linkXs,
                  url: 'https://dify.ai/privacy',
                  hoverUnderline: true,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AuthInlineLinks(
              style: tertiaryXs,
              spans: [
                '${tLogin(context, 'goToInit')} ',
                AuthSpanLink(
                  tLogin(context, 'setAdminAccount'),
                  style: linkXs,
                  hoverUnderline: true,
                  onTap: () => auth.go(const InstallRoute()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "no login method" card Dify shows when the invitation check failed (`allMethodsAreDisabled`).
class _NoLoginMethod extends StatelessWidget {
  const _NoLoginMethod();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          gradient: const LinearGradient(
            colors: [DifyColors.workflowWorkflowProgressBg1, DifyColors.workflowWorkflowProgressBg2],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: DifyColors.componentsCardBg,
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                boxShadow: DifyShadows.lg,
              ),
              alignment: Alignment.center,
              child: const RemixIcon('door-lock-line', size: 20, color: DifyColors.textPrimary),
            ),
            Text(
              tLogin(context, 'noLoginMethod'),
              style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tLogin(context, 'noLoginMethodTip'),
                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
      Container(
        height: 1,
        margin: const EdgeInsets.symmetric(vertical: 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              DifyColors.backgroundGradientMaskTransparent,
              DifyColors.dividerRegular,
              DifyColors.backgroundGradientMaskTransparent,
            ],
          ),
        ),
      ),
    ],
  );
}

/// components/mail-and-password-auth.tsx: email (disabled and prefilled on an invitation), password with the
/// visibility button and the disabled "Forgot your password?" link (no mail server), and "Sign in".
class MailAndPasswordAuth extends StatefulWidget {
  const MailAndPasswordAuth({super.key, required this.route, this.invite, this.isEmailSetup = false});
  final SignInRoute route;
  final InvitationCheck? invite;

  /// `systemFeatures.is_email_setup`: dify-sf sends no mail, so the reset link is disabled.
  final bool isEmailSetup;

  @override
  State<MailAndPasswordAuth> createState() => _MailAndPasswordAuthState();
}

class _MailAndPasswordAuthState extends State<MailAndPasswordAuth> {
  late final _email = AuthField(value: widget.route.email ?? widget.invite?.email ?? '');
  late final _password = AuthField();
  bool _loading = false;

  bool get _isInvite => widget.route.isInvite;

  @override
  void didUpdateWidget(MailAndPasswordAuth old) {
    super.didUpdateWidget(old);
    final email = widget.invite?.email;
    if (_isInvite && email != null && _email.value.isEmpty) _email.value = email;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setValidators(BuildContext context) {
    _email.validate = (v) {
      if (v.isEmpty) return tLogin(context, 'error.emailEmpty');
      return emailRegex.hasMatch(v) ? null : tLogin(context, 'error.emailInValid');
    };
    // `required`; on an invitation the password becomes the new account's, so Dify's password rule applies here
    // already (dify-sf activates with it; Dify sets it at this step without checking the rule).
    _password.validate = (v) {
      if (v.isEmpty) return tLogin(context, 'error.passwordEmpty');
      if (_isInvite && !validPassword.hasMatch(v)) return tLogin(context, 'error.passwordInvalid');
      return null;
    };
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (!submitAuthForm(_isInvite ? [_password] : [_email, _password])) return;
    final auth = AuthScope.read(context);
    if (auth == null) return;
    if (_isInvite) {
      auth.continueInvite(inviteToken: widget.route.inviteToken!, password: _password.value);
      return;
    }
    setState(() => _loading = true);
    try {
      await auth.signIn(email: _email.value, password: _password.value);
    } on TransportException catch (e) {
      if (!mounted) return;
      toast.error(
        e.code == 'invalid_credentials' || e.code == 'authentication_failed'
            ? tLogin(context, 'error.invalidEmailOrPassword')
            : e.message,
      );
    } on Object catch (e) {
      if (mounted) toast.error('$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _setValidators(context);
    final forgetColor = widget.isEmailSetup
        ? DifyColors.componentsButtonSecondaryAccentText
        : DifyColors.componentsButtonSecondaryAccentTextDisabled;
    return AuthSubmitOnEnter(
      onSubmit: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthTextField(
            key: const ValueKey('signin-email'),
            field: _email,
            label: tLogin(context, 'email'),
            placeholder: tLogin(context, 'emailPlaceholder'),
            disabled: _isInvite,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          AuthTextField(
            key: const ValueKey('signin-password'),
            field: _password,
            label: tLogin(context, 'password'),
            placeholder: tLogin(context, 'passwordPlaceholder'),
            password: true,
            revealButtonSize: DifyIconButtonSize.lg,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submit(),
            labelTrailing: ExcludeFocus(
              excluding: !widget.isEmailSetup,
              child: Semantics(
                link: true,
                enabled: widget.isEmailSetup,
                child: Text(
                  tLogin(context, 'forget'),
                  style: difyTextStyle(DifyType.systemXsRegular, forgetColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DifyButton(
              key: const ValueKey('signin-submit'),
              variant: DifyButtonVariant.primary,
              loading: _loading,
              onPressed: _submit,
              child: Text(tLogin(context, 'signBtn')),
            ),
          ),
        ],
      ),
    );
  }
}
