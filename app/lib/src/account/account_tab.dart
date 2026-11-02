/// The phone home's Account tab (compact windows): the account header, the workspace (switcher, members) and the
/// account's settings as pushed pages (My Account, Preferences), switching the server and logging out. Wider windows
/// keep Dify's account menu, workspace card and settings modal. A dify-sf divergence: Dify's console has no phone
/// layout.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppsApi;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../auth/auth_controller.dart';
import '../auth/server_address_form.dart' show serverText, showServerAddressDialog;
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../server_connection.dart';
import '../settings/members/members_page.dart';
import '../settings/preference_page.dart';
import '../settings/settings_kit.dart';
import '../settings/workspace_members.dart';
import '../shell/phone_page.dart';
import 'account_page.dart' show AccountPageBody;

/// The Account tab: a [DifyTopAppBar.large] over a list on components-panel-bg.
class AccountTab extends StatefulWidget {
  const AccountTab({super.key, required this.members, this.apps});

  /// The workspace's members (the workspace's name, the Members page).
  final WorkspaceMembers members;

  /// The session's apps ("Account's data" on the My Account page).
  final AppsApi? apps;

  @override
  State<AccountTab> createState() => _AccountTabState();
}

class _AccountTabState extends State<AccountTab> {
  WorkspaceMembers get _m => widget.members;

  @override
  void initState() {
    super.initState();
    _m.addListener(_changed);
    if (!_m.loaded && !_m.loading) unawaited(_m.refresh());
  }

  @override
  void didUpdateWidget(AccountTab old) {
    super.didUpdateWidget(old);
    if (old.members != widget.members) {
      old.members.removeListener(_changed);
      widget.members.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _m.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openAccount() => unawaited(
    pushPhonePage<void>(
      context,
      title: stc(context, 'account.myAccount'),
      builder: (_) => AccountPageBody(apps: widget.apps),
    ),
  );

  void _openMembers() => unawaited(
    pushPhonePage<void>(
      context,
      title: stc(context, 'settings.members'),
      builder: (_) => MembersPage(members: _m),
    ),
  );

  void _openPreferences() => unawaited(
    pushPhonePage<void>(
      context,
      title: stc(context, 'settings.preferences'),
      builder: (_) => const PreferencePage(),
    ),
  );

  /// The workspace switcher (Dify's main-nav switcher): dify-sf has the server's one workspace, so the sheet lists
  /// it as the current one and offers its settings.
  void _switchWorkspace(String name) => unawaited(
    showDifyActionSheet(
      context,
      title: stc(context, 'mobile.switchWorkspace'),
      actions: [
        DifyActionSheetAction(
          label: name,
          icon: const RemixIcon('check-line', size: 20),
          // The current workspace: nothing to switch to.
          onTap: () {},
        ),
        DifyActionSheetAction(
          label: stc(context, 'mainNav.workspace.settings'),
          icon: const RemixIcon('settings-3-line', size: 20),
          onTap: _openMembers,
        ),
      ],
    ),
  );

  /// Asks first (a tap on a phone is easily a mistake), then signs out once the dialog has closed: the sign-in page
  /// replaces the home and AppRoot closes every page above it.
  Future<void> _logout(AuthController auth) async {
    final ok = await showDifyConfirm(
      context,
      title: stc(context, 'mobile.logoutConfirm'),
      description: auth.account?.email,
      confirmLabel: stc(context, 'userProfile.logout'),
      dismissible: true,
      confirmKey: const ValueKey('account-tab-logout-confirm'),
    );
    if (ok) await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final account = auth.account;
    final connection = ServerConnectionScope.maybeOf(context);
    final workspace = _m.workspaceName;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ColoredBox(
      color: DifyColors.componentsPanelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTopAppBar.large(title: stc(context, 'account.account')),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: ListView(
                key: const ValueKey('account-tab-list'),
                padding: EdgeInsets.only(bottom: 16 + bottom),
                children: [
                  if (account != null)
                    DifyListRow(
                      key: const ValueKey('account-tab-profile'),
                      leading: DifyAvatar(name: account.name, url: account.avatarUrl, size: DifyAvatarSize.xxl),
                      title: account.name,
                      subtitle: account.email,
                      strong: true,
                      trailing: const [DifyListChevron()],
                      onTap: _openAccount,
                    ),
                  DifyListSectionHeader(stc(context, 'settings.workspace')),
                  if (workspace != null)
                    DifyListRow(
                      key: const ValueKey('account-tab-workspace'),
                      leading: DifyWorkspaceAvatar(name: workspace, size: DifyWorkspaceAvatarSize.lg),
                      title: workspace,
                      subtitle: stc(context, 'mobile.switchWorkspace'),
                      trailing: [RemixIcon('expand-up-down-line', size: 20, color: DifyColors.textTertiary)],
                      onTap: () => _switchWorkspace(workspace),
                    ),
                  DifyListRow(
                    key: const ValueKey('account-tab-members'),
                    leading: const RemixIcon('group-2-line', size: 20),
                    title: stc(context, 'settings.members'),
                    trailing: const [DifyListChevron()],
                    onTap: _openMembers,
                  ),
                  DifyListSectionHeader(stc(context, 'account.account')),
                  DifyListRow(
                    key: const ValueKey('account-tab-my-account'),
                    leading: const RemixIcon('account-circle-line', size: 20),
                    title: stc(context, 'account.myAccount'),
                    trailing: const [DifyListChevron()],
                    onTap: _openAccount,
                  ),
                  DifyListRow(
                    key: const ValueKey('account-tab-preferences'),
                    leading: const RemixIcon('equalizer-2-line', size: 20),
                    title: stc(context, 'settings.preferences'),
                    subtitle: [
                      stc(context, 'account.appearanceLabel'),
                      stc(context, 'language.displayLanguage'),
                      stc(context, 'language.timezone'),
                    ].join(' · '),
                    trailing: const [DifyListChevron()],
                    onTap: _openPreferences,
                  ),
                  const SizedBox(height: 20),
                  if (!kIsWeb && (connection?.canChange ?? false))
                    DifyListRow(
                      key: const ValueKey('account-tab-switch-server'),
                      leading: const RemixIcon('global-line', size: 20),
                      title: serverText(context, 'switch'),
                      subtitle: connection!.server,
                      onTap: () => unawaited(showServerAddressDialog(context, connection)),
                    ),
                  DifyListRow(
                    key: const ValueKey('account-tab-logout'),
                    leading: const RemixIcon('shut-down-line', size: 20),
                    title: stc(context, 'userProfile.logout'),
                    destructive: true,
                    divider: false,
                    onTap: () => unawaited(_logout(auth)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
