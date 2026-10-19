/// header/account-setting/preference-page (Dify 1.17.1): the account setting's Preferences tab ("General"): the
/// appearance (light / dark / system, the app's own setting as next-themes is the browser's), the display language and
/// the time zone. Language and time zone are the account's (`PATCH /v1/account/profile`, protocol 1.12); the language
/// also switches the app at once (Dify's `setLocaleOnClient(locale, false)`).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../auth/auth_controller.dart';
import '../design/dify_theme_mode.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_locales.g.dart';
import 'members/member_menu.dart' show requestErrorMessage;
import 'settings_kit.dart';

/// PreferencePage: three `mb-6` sections, each a `mb-1 system-sm-medium text-text-secondary` title over a medium
/// Select (named by its title). Language and time zone are disabled while a change is saved; each change toasts
/// "Modified successfully" or the error. The language shows the app's current one (else the account's), the time zone
/// the account's; values outside the lists show "Please select".
class PreferencePage extends StatefulWidget {
  const PreferencePage({super.key});

  @override
  State<PreferencePage> createState() => _PreferencePageState();
}

class _PreferencePageState extends State<PreferencePage> {
  bool _editing = false;

  Future<void> _save(Future<void> Function(AuthController auth) change) async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    setState(() => _editing = true);
    try {
      await change(auth);
      if (mounted) toast.success(stc(context, 'actionMsg.modifiedSuccessfully'));
    } on Object catch (e) {
      toast.error(requestErrorMessage(e));
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _language(String value) => _save((auth) async {
    await auth.session.updateProfile(interfaceLanguage: value);
    if (mounted) await AppLocaleScope.read(context)?.set(value);
  });

  Future<void> _timezone(String value) => _save((auth) async {
    await auth.session.updateProfile(timezone: value);
  });

  Widget _section(String title, Widget select) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(title, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
        ),
        select,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final account = AuthScope.maybeOf(context)?.account;
    final theme = AppThemeScope.of(context);
    final locale = AppLocaleScope.read(context) == null ? null : AppLocaleScope.of(context);
    final languages = AppLocale.supported;
    final languageValue = locale ?? account?.interfaceLanguage;
    final language = languages.any((l) => l.value == languageValue) ? languageValue : null;
    final timezone = difyTimezones.any((t) => t.value == account?.timezone) ? account?.timezone : null;
    final placeholder = stc(context, 'placeholder.select');
    final appearance = stc(context, 'account.appearanceLabel');
    final displayLanguage = stc(context, 'language.displayLanguage');
    final timezoneLabel = stc(context, 'language.timezone');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          appearance,
          DifySelect<DifyThemeMode>(
            key: const ValueKey('preference-appearance'),
            semanticLabel: appearance,
            value: theme?.mode ?? DifyThemeMode.system,
            disabled: theme == null,
            options: [
              (value: DifyThemeMode.system, label: stc(context, 'account.appearanceFollowSystem')),
              (value: DifyThemeMode.light, label: stc(context, 'account.appearanceLight')),
              (value: DifyThemeMode.dark, label: stc(context, 'account.appearanceDark')),
            ],
            onChanged: (mode) => unawaited(theme?.set(mode)),
          ),
        ),
        _section(
          displayLanguage,
          DifySelect<String>(
            key: const ValueKey('preference-language'),
            semanticLabel: displayLanguage,
            value: language,
            placeholder: placeholder,
            disabled: _editing,
            options: [for (final l in languages) (value: l.value, label: l.name)],
            onChanged: (v) => unawaited(_language(v)),
          ),
        ),
        _section(
          timezoneLabel,
          DifySelect<String>(
            key: const ValueKey('preference-timezone'),
            semanticLabel: timezoneLabel,
            value: timezone,
            placeholder: placeholder,
            disabled: _editing,
            options: [for (final t in difyTimezones) (value: t.value, label: t.name)],
            onChanged: (v) => unawaited(_timezone(v)),
          ),
        ),
      ],
    );
  }
}
