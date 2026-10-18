/// web/app/install (Dify 1.17.1): install/page.tsx around installForm.tsx, the first owner's account.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import 'auth_api.dart' show TransportException;
import 'auth_controller.dart';
import 'validation.dart';
import 'widgets/auth_widgets.dart';

class InstallPage extends StatelessWidget {
  const InstallPage({super.key});

  @override
  Widget build(BuildContext context) => const AuthPageFrame(child: InstallForm());
}

/// Checks the setup status first (finished: to the sign-in page), then asks for the email, name (at most 30
/// characters) and password (Dify's rule, shown as a hint until it fails) of the admin account; "Set up" creates it,
/// signs in and goes home.
class InstallForm extends StatefulWidget {
  const InstallForm({super.key});

  @override
  State<InstallForm> createState() => _InstallFormState();
}

class _InstallFormState extends State<InstallForm> {
  final _email = AuthField();
  final _name = AuthField();
  final _password = AuthField();
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkSetup());
  }

  Future<void> _checkSetup() async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    try {
      final step = await auth.setupStatus();
      if (!mounted) return;
      if (step == 'finished') return auth.go(const SignInRoute());
    } on Object catch (e) {
      if (mounted) toast.error(e is TransportException ? e.message : '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!submitAuthForm([_email, _name, _password])) return;
    final auth = AuthScope.read(context);
    if (auth == null) return;
    setState(() => _submitting = true);
    try {
      // Dify sets up, then signs in with the same credentials; protocol 1.8's setup answers with the session.
      await auth.install(
        email: _email.value,
        name: _name.value,
        password: _password.value,
        language: AppLocaleScope.read(context)?.language,
      );
    } on TransportException catch (e) {
      if (!mounted) return;
      toast.error(e.message);
      if (e.code == 'setup_done') auth.go(const SignInRoute());
    } on Object catch (e) {
      if (mounted) toast.error('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.only(top: 8), child: DifyAreaLoading());
    _email.validate = (v) => zodEmailRegex.hasMatch(v) ? null : tLogin(context, 'error.emailInValid');
    _name.validate = (v) => v.isEmpty ? tLogin(context, 'error.nameEmpty') : null;
    _password.validate = (v) =>
        v.length >= 8 && validPassword.hasMatch(v) ? null : tLogin(context, 'error.passwordInvalid');
    final title = tLogin(context, 'setAdminAccount');
    // `sm:mx-auto sm:w-full sm:max-w-md`.
    Widget column(Widget child) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width >= 640 ? 448 : double.infinity),
        child: child,
      ),
    );
    return AuthSubmitOnEnter(
      onSubmit: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          column(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthHeading(
                  title,
                  style: const TextStyle(
                    fontSize: 32,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                    color: DifyColors.textPrimary,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tLogin(context, 'setAdminAccountDesc'),
                    style: const TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          column(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthTextField(
                  key: const ValueKey('install-email'),
                  field: _email,
                  label: tLogin(context, 'email'),
                  placeholder: tLogin(context, 'emailPlaceholder'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 20),
                AuthTextField(
                  key: const ValueKey('install-name'),
                  field: _name,
                  label: tLogin(context, 'name'),
                  placeholder: tLogin(context, 'namePlaceholder'),
                  maxLength: 30,
                  autofillHints: const [AutofillHints.name],
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 20),
                AuthTextField(
                  key: const ValueKey('install-password'),
                  field: _password,
                  label: tLogin(context, 'password'),
                  placeholder: tLogin(context, 'passwordPlaceholder'),
                  password: true,
                  autofillHints: const [AutofillHints.newPassword],
                  description: tLogin(context, 'error.passwordInvalid'),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 20),
                DifyButton(
                  key: const ValueKey('install-submit'),
                  variant: DifyButtonVariant.primary,
                  loading: _submitting,
                  onPressed: _submit,
                  child: Text(tLogin(context, 'installBtn')),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AuthInlineLinks(
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textSecondary),
                    spans: [
                      '${tLogin(context, 'license.tip')} ',
                      AuthSpanLink(
                        tLogin(context, 'license.link'),
                        style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textAccent),
                        url: difyLicenseLink,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
