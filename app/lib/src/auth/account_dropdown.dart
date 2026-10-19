/// web/app/components/header/account-dropdown (Dify 1.17.1) and the main nav's account-section.tsx that opens it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../account/account_page.dart';
import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_theme_mode.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import '../settings/account_setting.dart';
import '../settings/workspace_members.dart';
import 'auth_api.dart';
import 'auth_controller.dart';

String _tc(BuildContext context, String key) {
  AppLocaleScope.of(context);
  return DifyI18n.tr('common', key);
}

/// Opens the account setting on Preferences (Dify's `setSettingsDestination('preferences')`): with [members] when the
/// page shares them, else with its own for the session (released when the dialog closes).
Future<void> openPreferences(BuildContext context, {WorkspaceMembers? members}) async {
  if (members != null) {
    return showAccountSetting(context, members: members, tab: AccountSettingTab.preferences);
  }
  final auth = AuthScope.read(context);
  if (auth == null) return;
  final own = WorkspaceMembers(auth);
  try {
    await showAccountSetting(context, members: own, tab: AccountSettingTab.preferences);
  } finally {
    own.dispose();
  }
}

/// AccountDropdown: [trigger] (given the accessible name "Account" and whether the menu is open) opens the menu
/// `top-start`, 6 px away, 4 px along, `w-60` on the blurred panel background without padding. Logging out signs out
/// ([onLogout]; by default the [AuthScope]'s controller, which brings the sign-in page back). "Account" opens the
/// Account page ([onOpenAccount]; [openAccountPage] by default), "Preferences" the account setting's Preferences
/// ([onOpenPreferences]; [openPreferences] with [members] by default).
class AccountDropdown extends StatelessWidget {
  const AccountDropdown({
    super.key,
    required this.trigger,
    required this.account,
    this.onLogout,
    this.onOpenAccount,
    this.onOpenPreferences,
    this.members,
  });

  final Widget Function(BuildContext context, String ariaLabel, bool open, VoidCallback toggle) trigger;
  final Account account;
  final Future<void> Function()? onLogout;
  final VoidCallback? onOpenAccount, onOpenPreferences;
  final WorkspaceMembers? members;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    placement: DifyPlacement.topStart,
    sideOffset: 6,
    alignOffset: 4,
    width: 240,
    builder: (context, controller) =>
        trigger(context, _tc(context, 'account.account'), controller.isOpen, controller.toggle),
    children: [
      MainNavMenuContent(
        account: account,
        onLogout: onLogout ?? () async => AuthScope.read(context)?.signOut(),
        onOpenAccount: onOpenAccount ?? () => unawaited(openAccountPage(context)),
        onOpenPreferences: onOpenPreferences ?? () => unawaited(openPreferences(context, members: members)),
      ),
    ],
  );
}

/// main-nav-menu-content.tsx: the account card (name, email, the `lg` avatar on a `rounded-xl` gradient), the group
/// with "Account" (`i-ri-account-circle-line`, the `i-ri-arrow-right-up-line` link indicator), "Preferences"
/// (`i-ri-equalizer-2-line`) and the Appearance submenu (light / dark / system, [AppThemeScope]'s choice), then "Log
/// out". Items are `mx-0 h-8 gap-1 px-3 py-1`.
class MainNavMenuContent extends StatelessWidget {
  const MainNavMenuContent({
    super.key,
    required this.account,
    required this.onLogout,
    this.onOpenAccount,
    this.onOpenPreferences,
  });

  final Account account;
  final Future<void> Function() onLogout;
  final VoidCallback? onOpenAccount, onOpenPreferences;

  Widget _label(BuildContext context, String key) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      _tc(context, key),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // DropdownMenuGroup `p-1` (the popup's own 4 px stands in for the top padding).
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [DifyColors.backgroundSectionBurn, DifyColors.backgroundSection],
            ),
          ),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.bodyMdMedium, DifyColors.textPrimary),
                    ),
                    Text(
                      account.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                    ),
                  ],
                ),
              ),
              DifyAvatar(name: account.name, url: account.avatarUrl, size: DifyAvatarSize.lg),
            ],
          ),
        ),
      ),
      // DropdownMenuGroup `p-1`: Account, Preferences, the Appearance submenu.
      Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifyMenuItem(
              key: const ValueKey('account-open-account'),
              marginX: 0,
              paddingX: 12,
              semanticLabel: _tc(context, 'account.account'),
              onSelect: onOpenAccount,
              leading: RemixIcon('account-circle-line', size: 16, color: DifyColors.textTertiary),
              trailing: RemixIcon('arrow-right-up-line', size: 14, color: DifyColors.textTertiary),
              child: _label(context, 'account.account'),
            ),
            DifyMenuItem(
              key: const ValueKey('account-open-preferences'),
              marginX: 0,
              paddingX: 12,
              semanticLabel: _tc(context, 'settings.preferences'),
              onSelect: onOpenPreferences,
              leading: RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
              child: _label(context, 'settings.preferences'),
            ),
            if (AppThemeScope.of(context) case final theme?) AppearanceSubmenu(theme: theme),
          ],
        ),
      ),
      // DropdownMenuSeparator `my-0! bg-divider-subtle`.
      Container(height: 1, color: DifyColors.dividerSubtle),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: DifyMenuItem(
          key: const ValueKey('account-logout'),
          marginX: 0,
          paddingX: 12,
          onSelect: () => unawaited(onLogout()),
          leading: RemixIcon('shut-down-line', size: 16, color: DifyColors.textTertiary),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _tc(context, 'userProfile.logout'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
            ),
          ),
        ),
      ),
    ],
  );
}

/// AppearanceSubmenu (main-nav-menu-content.tsx): the `mx-0 h-8 gap-1 px-3 py-1` trigger (`i-ri-sun-line`,
/// "Appearance"), opening `right-start` 6 px away a `w-34.75` radio group (`mx-0 h-8 gap-1 px-2 py-1` items with
/// `closeOnClick`): Light (`i-ri-sun-line`), Dark (`i-ri-moon-line`), System (`i-ri-computer-line`).
class AppearanceSubmenu extends StatelessWidget {
  const AppearanceSubmenu({super.key, required this.theme});

  final AppTheme theme;

  @override
  Widget build(BuildContext context) {
    Widget label(String key) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        _tc(context, key),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
      ),
    );
    Widget item(DifyThemeMode mode, String icon, String key) => DifyMenuRadioItem<DifyThemeMode>(
      key: ValueKey('appearance-${mode.name}'),
      value: mode,
      closeOnClick: true,
      leading: RemixIcon(icon, size: 16, color: DifyColors.textTertiary),
      child: label(key),
    );
    return DifyMenuSubmenu(
      key: const ValueKey('account-appearance'),
      placement: DifyPlacement.rightStart,
      sideOffset: 6,
      // `w-34.75`, border-box.
      width: 139 - 2 * Css.hairline,
      paddingX: 12,
      leading: RemixIcon('sun-line', size: 16, color: DifyColors.textTertiary),
      label: label('account.appearanceLabel'),
      semanticLabel: _tc(context, 'account.appearanceLabel'),
      children: [
        DifyMenuRadioGroup<DifyThemeMode>(
          value: theme.mode,
          onValueChange: (mode) => unawaited(theme.set(mode)),
          children: [
            item(DifyThemeMode.light, 'sun-line', 'account.appearanceLight'),
            item(DifyThemeMode.dark, 'moon-line', 'account.appearanceDark'),
            item(DifyThemeMode.system, 'computer-line', 'account.appearanceSystem'),
          ],
        ),
      ],
    );
  }
}

/// main-nav/components/account-section.tsx: the round trigger with the 28 px avatar and the name (`max-w-45 gap-3
/// py-1 pr-4 pl-1 system-md-medium text-components-main-nav-text`, hover / open `bg-state-base-hover`); [compact]
/// shows only the avatar (`p-1`). Its accessible name is the name and "Account".
class AccountSection extends StatelessWidget {
  const AccountSection({
    super.key,
    required this.account,
    this.compact = false,
    this.onLogout,
    this.members,
    this.onOpenAccount,
  });

  final Account account;
  final bool compact;
  final Future<void> Function()? onLogout;

  /// The workspace's members the page shares (Preferences opens the account setting with them).
  final WorkspaceMembers? members;

  /// Opens the Account page ([openAccountPage] by default).
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) => AccountDropdown(
    account: account,
    onLogout: onLogout,
    members: members,
    onOpenAccount: onOpenAccount,
    trigger: (context, ariaLabel, open, toggle) => _AccountTrigger(
      account: account,
      compact: compact,
      label: '${account.name} $ariaLabel',
      open: open,
      onTap: toggle,
    ),
  );
}

class _AccountTrigger extends StatefulWidget {
  const _AccountTrigger({
    required this.account,
    required this.compact,
    required this.label,
    required this.open,
    required this.onTap,
  });
  final Account account;
  final bool compact;
  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_AccountTrigger> createState() => _AccountTriggerState();
}

class _AccountTriggerState extends State<_AccountTrigger> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final avatar = DifyAvatar(name: w.account.name, url: w.account.avatarUrl, box: 28);
    return Semantics(
      button: true,
      label: w.label,
      onTap: w.onTap,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const ValueKey('account-trigger'),
          onTap: w.onTap,
          child: Container(
            constraints: w.compact ? null : const BoxConstraints(maxWidth: 180),
            padding: w.compact ? const EdgeInsets.all(4) : const EdgeInsets.fromLTRB(4, 4, 16, 4),
            decoration: BoxDecoration(
              color: _hover || w.open ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(999),
            ),
            child: w.compact
                ? avatar
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      avatar,
                      Flexible(
                        child: Text(
                          w.account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemMdMedium, DifyColors.componentsMainNavText),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
