/// web/app/components/header/account-dropdown (Dify 1.17.1) and the main nav's account-section.tsx that opens it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import 'auth_api.dart';
import 'auth_controller.dart';

String _tc(BuildContext context, String key) {
  AppLocaleScope.of(context);
  return DifyI18n.tr('common', key);
}

/// AccountDropdown: [trigger] (given the accessible name "Account" and whether the menu is open) opens the menu
/// `top-start`, 6 px away, 4 px along, `w-60` on the blurred panel background without padding. Logging out signs out
/// ([onLogout]; by default the [AuthScope]'s controller, which brings the sign-in page back).
class AccountDropdown extends StatelessWidget {
  const AccountDropdown({super.key, required this.trigger, required this.account, this.onLogout});

  final Widget Function(BuildContext context, String ariaLabel, bool open, VoidCallback toggle) trigger;
  final Account account;
  final Future<void> Function()? onLogout;

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
      ),
    ],
  );
}

/// main-nav-menu-content.tsx: the account card (name, email, the `lg` avatar on a `rounded-xl` gradient), then
/// "Log out". Dify's Account page link, Preferences and Appearance are not shown: dify-sf has no account page,
/// preferences dialog or dark theme yet.
class MainNavMenuContent extends StatelessWidget {
  const MainNavMenuContent({super.key, required this.account, required this.onLogout});

  final Account account;
  final Future<void> Function() onLogout;

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
            gradient: const LinearGradient(
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
      // DropdownMenuSeparator `my-0! bg-divider-subtle`.
      Container(height: 1, color: DifyColors.dividerSubtle),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: DifyMenuItem(
          key: const ValueKey('account-logout'),
          marginX: 0,
          paddingX: 12,
          onSelect: () => unawaited(onLogout()),
          leading: const RemixIcon('shut-down-line', size: 16, color: DifyColors.textTertiary),
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

/// main-nav/components/account-section.tsx: the round trigger with the 28 px avatar and the name (`max-w-45 gap-3
/// py-1 pr-4 pl-1 system-md-medium text-components-main-nav-text`, hover / open `bg-state-base-hover`); [compact]
/// shows only the avatar (`p-1`). Its accessible name is the name and "Account".
class AccountSection extends StatelessWidget {
  const AccountSection({super.key, required this.account, this.compact = false, this.onLogout});

  final Account account;
  final bool compact;
  final Future<void> Function()? onLogout;

  @override
  Widget build(BuildContext context) => AccountDropdown(
    account: account,
    onLogout: onLogout,
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
