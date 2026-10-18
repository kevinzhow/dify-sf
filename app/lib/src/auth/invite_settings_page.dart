/// web/app/signin/invite-settings (Dify 1.17.1): the invited account's name, interface language and time zone, and
/// "Join {workspace}".
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import '../i18n/dify_locales.g.dart';
import '../local_timezone.dart';
import '../workflow_editor/panel_fields/selectors.dart' show DifySelect;
import 'activate_page.dart' show InvalidInvitation;
import 'auth_api.dart';
import 'auth_controller.dart';
import 'validation.dart';
import 'widgets/auth_widgets.dart';

class InviteSettingsPage extends StatelessWidget {
  const InviteSettingsPage({super.key, required this.inviteToken, this.browserTimezone});
  final String inviteToken;

  /// The system's time zone (tests); null asks the platform.
  final String? Function()? browserTimezone;

  @override
  Widget build(BuildContext context) => SignInLayout(
    child: InviteSettingsForm(inviteToken: inviteToken, browserTimezone: browserTimezone),
  );
}

/// Dify's page needs the invited account signed in (its sign-in step set the password); dify-sf's sign-in step keeps
/// the password for the activation instead. Without it (or signed in as someone else) the page goes back to the
/// invitation's sign-in.
class InviteSettingsForm extends StatefulWidget {
  const InviteSettingsForm({super.key, required this.inviteToken, this.browserTimezone});
  final String inviteToken;
  final String? Function()? browserTimezone;

  @override
  State<InviteSettingsForm> createState() => _InviteSettingsFormState();
}

class _InviteSettingsFormState extends State<InviteSettingsForm> {
  final _name = AuthField();
  InvitationCheck? _check;
  bool _activating = false;
  late String _language;
  late String _timezone;

  @override
  void initState() {
    super.initState();
    final locale = AppLocaleScope.read(context)?.language ?? DifyI18n.fallbackLanguage;
    // getInitialLanguage: the UI language when Dify supports it, else the default.
    _language = AppLocale.supported.any((l) => l.value == locale) ? locale : DifyI18n.fallbackLanguage;
    _timezone = (widget.browserTimezone ?? localTimezone)() ?? 'America/Los_Angeles';
    unawaited(_recheck());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    InvitationCheck r;
    try {
      r = await auth.checkInvitation(widget.inviteToken);
    } on Object {
      r = const InvitationCheck(isValid: false);
    }
    if (!mounted) return;
    setState(() => _check = r);
    _guard();
  }

  /// `shouldReturnToSignIn`: a valid invitation, but not signed in as the invited account (dify-sf: and no password
  /// from the sign-in step).
  bool _returnToSignIn(AuthController auth) {
    final c = _check;
    if (c == null || !c.isValid) return false;
    if (auth.signedIn) return !isInvitationForAccount(c.email, auth.account?.email);
    return !auth.hasInvitePassword;
  }

  void _guard() {
    final auth = AuthScope.read(context);
    if (auth != null && _returnToSignIn(auth)) {
      auth.go(SignInRoute(inviteToken: widget.inviteToken, email: _check?.email));
    }
  }

  Future<void> _activate() async {
    final c = _check;
    final auth = AuthScope.read(context);
    if (_activating || c == null || auth == null) return;
    final setup = c.needsSetup;
    if (!setup) {
      // Dify activates an existing account with the token alone. Protocol 1.8 invites only new accounts (the check never
      // says otherwise), so there is nothing to join: a signed-in member goes home.
      if (auth.signedIn) auth.go(const HomeRoute());
      return;
    }
    if (!submitAuthForm([_name])) return;
    setState(() => _activating = true);
    try {
      await auth.activate(
        token: widget.inviteToken,
        name: _name.value,
        interfaceLanguage: _language,
        timezone: _timezone,
      );
      if (mounted) await AppLocaleScope.read(context)?.set(_language);
    } on Object catch (e) {
      if (!mounted) return;
      toast.error(e is TransportException ? e.message : '$e');
      setState(() => _activating = false);
      unawaited(_recheck());
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final c = _check;
    final setupTitle = tLogin(context, 'setYourAccount');
    final workspace = c?.workspaceName ?? '';
    final joinTitle = workspace.isNotEmpty
        ? tLogin(context, 'joinWorkspace', {'workspaceName': workspace})
        : setupTitle;
    final docTitle = c == null
        ? setupTitle
        : !c.isValid
        ? tLogin(context, 'invalid')
        : c.needsSetup || workspace.isEmpty
        ? setupTitle
        : joinTitle;
    Widget body;
    if (c == null || _returnToSignIn(auth)) {
      body = const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: DifyAreaLoading());
    } else if (!c.isValid) {
      body = InvalidInvitation(onExplore: () => auth.go(const SignInRoute()));
    } else {
      body = _form(context, c, joinTitle);
    }
    return DifyDocumentTitle(title: docTitle, child: body);
  }

  Widget _form(BuildContext context, InvitationCheck c, String joinTitle) {
    final setup = c.needsSetup;
    _name.validate = (v) => v.trim().isEmpty ? tLogin(context, 'enterYourName') : null;
    final selectLabel = difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary);
    Widget labelled(String label, Widget control) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(label, style: selectLabel),
          ),
        ),
        control,
      ],
    );
    return AuthSubmitOnEnter(
      onSubmit: _activate,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: DifyColors.backgroundDefaultDodge,
                border: Border.all(color: DifyColors.componentsPanelBorderSubtle),
                borderRadius: BorderRadius.circular(16),
                boxShadow: DifyShadows.lg,
              ),
              alignment: Alignment.center,
              child: const RemixIcon('account-circle-line', size: 24, color: DifyColors.textAccentLightModeOnly),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: AuthHeading(
              setup ? tLogin(context, 'setYourAccount') : joinTitle,
              style: difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (setup) ...[
                AuthTextField(
                  key: const ValueKey('invite-name'),
                  field: _name,
                  label: tLogin(context, 'name'),
                  placeholder: tLogin(context, 'namePlaceholder'),
                  autofillHints: const [AutofillHints.name],
                  onSubmitted: (_) => _activate(),
                ),
                const SizedBox(height: 20),
                labelled(
                  tLogin(context, 'interfaceLanguage'),
                  DifySelect<String>(
                    key: const ValueKey('invite-language'),
                    large: true,
                    semanticLabel: tLogin(context, 'interfaceLanguage'),
                    value: _language,
                    placeholder: DifyI18n.tr('common', 'placeholder.select'),
                    options: [for (final l in AppLocale.supported) (value: l.value, label: l.name)],
                    onChanged: (v) => setState(() => _language = v),
                  ),
                ),
                const SizedBox(height: 20),
                labelled(
                  tLogin(context, 'timezone'),
                  DifySelect<String>(
                    key: const ValueKey('invite-timezone'),
                    large: true,
                    semanticLabel: tLogin(context, 'timezone'),
                    value: difyTimezones.any((t) => t.value == _timezone) ? _timezone : null,
                    placeholder: DifyI18n.tr('common', 'placeholder.select'),
                    options: [for (final t in difyTimezones) (value: t.value, label: t.name)],
                    onChanged: (v) => setState(() => _timezone = v),
                  ),
                ),
                const SizedBox(height: 20),
              ],
              DifyButton(
                key: const ValueKey('invite-submit'),
                variant: DifyButtonVariant.primary,
                loading: _activating,
                onPressed: _activate,
                child: Text(joinTitle),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AuthInlineLinks(
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
              spans: [
                '${tLogin(context, 'license.tip')} ',
                AuthSpanLink(
                  tLogin(context, 'license.link'),
                  style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccentSecondary),
                  url: difyLicenseLink,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
