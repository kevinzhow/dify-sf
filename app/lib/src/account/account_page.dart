/// web/app/account/(commonLayout) (Dify 1.17.1): the Account page (`/account`): its header (logo, "Account", Home, the
/// avatar menu) and account-page/index.tsx: the profile card, name, email, password and the account's apps. Protocol
/// 1.8 / 1.12 calls: `PUT /v1/account/name`, `PUT /v1/account/password`, the change-email flow, `GET /v1/apps`.
///
/// Not ported, as in Dify's community edition or for want of a server service: uploading an avatar (dify-sf has no file
/// storage; the avatar is Dify's initial fallback, as Dify with `DISABLE_UPLOAD_IMAGE_AS_ICON`), deleting the account
/// (Dify Cloud only) and the education badge (Dify Cloud only).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppInfo, AppListQuery, AppsApi;
import 'package:flutter/material.dart' show Material, MaterialPageRoute, MaterialType;
import 'package:flutter/widgets.dart';

import '../auth/auth_api.dart';
import '../auth/auth_controller.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../settings/settings_kit.dart';
import 'account_dialogs.dart';
import 'email_change_modal.dart';

/// Opens the Account page on the app's navigator (Dify's `<Link href="/account">`).
Future<void> openAccountPage(BuildContext context, {AppsApi? apps}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AccountPage(apps: apps)));

/// The page: `flex h-full flex-col bg-background-body`, the sticky header (`min-h-14`) and the scrolling content on
/// `bg-components-panel-bg` (`mx-auto w-full max-w-160 px-6 pt-12`). [onHome] leaves it (back to the app by default);
/// [apps] lists the account's apps (none without it).
class AccountPage extends StatelessWidget {
  const AccountPage({super.key, this.apps, this.onHome});

  final AppsApi? apps;
  final VoidCallback? onHome;

  @override
  Widget build(BuildContext context) {
    final home = onHome ?? () => Navigator.of(context).maybePop();
    return Material(
      type: MaterialType.transparency,
      // `useDocumentTitle(t('menus.account'))`: the page's name for assistive technology.
      child: Semantics(
        label: stc(context, 'menus.account'),
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        child: ColoredBox(
          color: DifyColors.backgroundBody,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: AccountHeader(onHome: home),
              ),
              Expanded(
                child: ColoredBox(
                  color: DifyColors.componentsPanelBg,
                  child: SingleChildScrollView(
                    key: const ValueKey('account-page-scroll'),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                          child: AccountPageBody(apps: apps),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// header.tsx: `flex flex-1 items-center justify-between px-4`: the logo (a link home, `h-5.5`), a `h-4 w-px
/// rotate-[11.31deg] bg-divider-regular` slash and "Account" (`title-3xl-semi-bold`); on the right the Home button
/// (`px-3 py-2 system-sm-medium`, main-nav home icon, `i-ri-arrow-right-up-line`), a `h-4 w-px` divider and the avatar
/// menu.
class AccountHeader extends StatelessWidget {
  const AccountHeader({super.key, required this.onHome});

  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final account = AuthScope.maybeOf(context)?.account;
    final home = stc(context, 'mainNav.home');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          DifyPressable(
            key: const ValueKey('account-header-logo'),
            semanticLabel: 'Dify',
            onPressed: onHome,
            builder: (context, hovered, focused) => Opacity(
              opacity: hovered ? 0.8 : 1,
              child: const DifyLogo(alt: ''),
            ),
          ),
          const SizedBox(width: 12),
          Transform.rotate(
            angle: 11.31 * 3.141592653589793 / 180,
            child: Container(width: 1, height: 16, color: DifyColors.dividerRegular),
          ),
          const SizedBox(width: 12),
          Transform.translate(
            offset: const Offset(0, -2),
            child: Text(
              stc(context, 'account.account'),
              style: difyTextStyle(DifyType.title3xlSemiBold, DifyColors.textPrimary),
            ),
          ),
          const Spacer(),
          DifyButton(
            key: const ValueKey('account-header-home'),
            semanticLabel: home,
            paddingX: 12,
            onPressed: onHome,
            leading: DifyIcon('vender/main-nav/home', size: 16, color: DifyColors.componentsButtonSecondaryText),
            trailing: RemixIcon('arrow-right-up-line', size: 16, color: DifyColors.componentsButtonSecondaryText),
            child: Text(home, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.componentsButtonSecondaryText)),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 16, color: DifyColors.dividerRegular),
          const SizedBox(width: 12),
          if (account != null) AccountAvatarMenu(account: account),
        ],
      ),
    );
  }
}

/// avatar.tsx: the `size-8` round trigger (named by the account's name) with the avatar, opening `bottom-end` 4 px
/// away a `w-60` menu on the blurred panel: the name and email beside the avatar (`px-3 py-2`), then "Log out"
/// (`h-9 px-3`, `log-out-01`). Logging out signs out ([onLogout]; by default the session's).
class AccountAvatarMenu extends StatelessWidget {
  const AccountAvatarMenu({super.key, required this.account, this.onLogout});

  final Account account;
  final Future<void> Function()? onLogout;

  @override
  Widget build(BuildContext context) {
    final logout = onLogout ?? () async => AuthScope.read(context)?.signOut();
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      width: 240,
      builder: (context, controller) => DifyPressable(
        key: const ValueKey('account-avatar-trigger'),
        semanticLabel: account.name,
        onPressed: controller.toggle,
        builder: (context, hovered, focused) => Opacity(
          opacity: hovered || controller.isOpen ? 0.8 : 1,
          child: DifyAvatar(name: account.name, url: account.avatarUrl),
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(account.name, style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary)),
                      Text(account.email, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
                    ],
                  ),
                ),
                DifyAvatar(name: account.name, url: account.avatarUrl),
              ],
            ),
          ),
        ),
        Container(height: 1, color: DifyColors.dividerSubtle),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: DifyMenuItem(
            key: const ValueKey('account-page-logout'),
            marginX: 0,
            paddingX: 12,
            onSelect: () => unawaited(logout()),
            leading: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: DifyIcon('vender/line/general/log-out-01', size: 16, color: DifyColors.textTertiary),
            ),
            child: Text(
              stc(context, 'userProfile.logout'),
              // `text-[14px] font-normal`.
              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// account-page/index.tsx: "My Account", the profile card (`rounded-xl` gradient `p-6`: the `3xl` avatar, name
/// `system-xl-semibold`, email), Name (Edit), Email (Change, when the server offers it), Password ("Reset password"),
/// a divider and "Account's data" with the account's apps ("Show N apps"; Dify lists the first 100).
class AccountPageBody extends StatefulWidget {
  const AccountPageBody({super.key, this.apps});

  final AppsApi? apps;

  @override
  State<AccountPageBody> createState() => _AccountPageBodyState();
}

class _AccountPageBodyState extends State<AccountPageBody> {
  List<AppInfo> _apps = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadApps());
  }

  Future<void> _loadApps() async {
    final api = widget.apps;
    if (api == null) return;
    try {
      final page = await api.list(const AppListQuery(limit: 100, name: ''));
      if (mounted) setState(() => _apps = page.data);
    } on Object {
      // Dify's useQuery: no list on failure.
    }
  }

  TextStyle get _title => difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary);

  /// A read-only value box (`flex-1 rounded-lg bg-components-input-bg-normal p-2 system-sm-regular`) with its action
  /// (a tertiary button).
  Widget _field(String label, String value, {String? action, Key? actionKey, VoidCallback? onAction}) => Padding(
    padding: const EdgeInsets.only(bottom: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: _title),
        const SizedBox(height: 8),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DifyColors.componentsInputBgNormal,
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    value,
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
                  ),
                ),
              ),
            ),
            if (action != null)
              // `rounded-lg bg-components-button-tertiary-bg px-3 py-2 system-sm-medium
              // text-components-button-tertiary-text`: the tertiary button.
              DifyButton(
                key: actionKey,
                semanticLabel: action,
                variant: DifyButtonVariant.tertiary,
                paddingX: 12,
                onPressed: onAction,
                child: Text(action),
              ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    final account = auth?.account;
    if (auth == null || account == null) return const SizedBox.shrink();
    final features = auth.systemFeatures;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: Semantics(
            header: true,
            child: Text(
              stc(context, 'account.myAccount'),
              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
            ),
          ),
        ),
        Container(
          key: const ValueKey('account-profile-card'),
          margin: const EdgeInsets.only(bottom: 32),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            gradient: LinearGradient(
              colors: [DifyColors.backgroundGradientBgFillChatBg2, DifyColors.backgroundGradientBgFillChatBg1],
            ),
          ),
          child: Row(
            children: [
              DifyAvatar(name: account.name, url: account.avatarUrl, size: DifyAvatarSize.xxxl),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.name, style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary)),
                    Text(account.email, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        _field(
          stc(context, 'account.name'),
          account.name,
          action: stc(context, 'operation.edit'),
          actionKey: const ValueKey('account-edit-name'),
          onAction: () => unawaited(showEditNameDialog(context, auth)),
        ),
        _field(
          stc(context, 'account.email'),
          account.email,
          action: features.enableChangeEmail ? stc(context, 'operation.change') : null,
          actionKey: const ValueKey('account-change-email'),
          onAction: () => unawaited(showEmailChangeModal(context, auth)),
        ),
        if (features.enableEmailPasswordLogin)
          Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(stc(context, 'account.password'), style: _title),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          stc(context, 'account.passwordTip'),
                          style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
                DifyButton(
                  key: const ValueKey('account-reset-password'),
                  semanticLabel: stc(context, 'account.resetPassword'),
                  onPressed: () => unawaited(showPasswordDialog(context, auth)),
                  // Every dify-sf account that can sign in has a password (Dify's `is_password_set`).
                  child: Text(stc(context, 'account.resetPassword')),
                ),
              ],
            ),
          ),
        // `mb-6 border border-divider-subtle`: an empty box with a 1 px border all round.
        Container(
          height: 2,
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(border: Border.all(color: DifyColors.dividerSubtle)),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(stc(context, 'account.langGeniusAccount'), style: _title),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  stc(context, 'account.langGeniusAccountTip'),
                  style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                ),
              ),
              if (_apps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DifyCollapse<AppInfo>(
                    title: stc(context, 'account.showAppLength', {'length': _apps.length}),
                    items: _apps,
                    itemBuilder: (context, app) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: DifyAppIcon(
                              size: DifyAppIconSize.tiny,
                              iconType: app.iconType,
                              icon: app.icon,
                              background: app.iconBackground,
                              imageUrl: app.iconUrl,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              app.name,
                              style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
