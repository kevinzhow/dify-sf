/// header/account-setting (index.tsx, menu-dialog.tsx, constants.ts): the full-screen "Settings" dialog with its
/// sidebar of tabs. dify-sf has the Members tab; Dify's other tabs need what dify-sf's server does not have (RBAC
/// roles and permission sets, billing, customization, log archives: none of them show in Dify's community edition
/// either) or account settings it cannot store yet (Preferences: language, theme, time zone). A tab is an
/// [AccountSettingTab] with its [AccountSettingItem].
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import 'members/members_page.dart';
import 'settings_kit.dart';
import 'workspace_members.dart';

/// `ACCOUNT_SETTING_TAB`, as far as dify-sf has the tabs.
enum AccountSettingTab { members }

/// The sidebar groups (`menuItems`): the workspace group (labelled "WORKSPACE") and the user group (below a
/// divider; Dify's Preferences, later dify-sf's own account settings).
enum AccountSettingGroup { workspace, user }

/// One tab: its sidebar entry (name, icon, active icon), the content header (title, else the name; description)
/// and the page.
class AccountSettingItem {
  const AccountSettingItem({
    required this.tab,
    required this.group,
    required this.name,
    required this.icon,
    required this.activeIcon,
    required this.page,
    this.title,
    this.description,
  });

  final AccountSettingTab tab;
  final AccountSettingGroup group;
  final String Function(BuildContext context) name;
  final String Function(BuildContext context)? title, description;

  /// Remix icon names (`i-ri-group-2-line` / `-fill`).
  final String icon, activeIcon;
  final Widget Function(BuildContext context, WorkspaceMembers members) page;
}

/// The tabs, in Dify's order.
final accountSettingItems = <AccountSettingItem>[
  AccountSettingItem(
    tab: AccountSettingTab.members,
    group: AccountSettingGroup.workspace,
    name: (context) => stc(context, 'settings.members'),
    icon: 'group-2-line',
    activeIcon: 'group-2-fill',
    page: (context, members) => MembersPage(members: members),
  ),
];

/// Opens the account setting on [tab] (Dify's `?settings=<tab>`); resolves when it closes.
Future<void> showAccountSetting(
  BuildContext context, {
  required WorkspaceMembers members,
  AccountSettingTab tab = AccountSettingTab.members,
}) => showGeneralDialog<void>(
  context: context,
  // Escape closes it (the content covers the transparent backdrop, so nothing else can be clicked outside).
  barrierDismissible: true,
  barrierLabel: 'Dismiss',
  barrierColor: const Color(0x00000000),
  transitionDuration: difyTransitionDuration,
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: difyTransitionCurve),
    child: child,
  ),
  pageBuilder: (context, _, _) => AccountSetting(members: members, initialTab: tab),
);

/// AccountSetting in MenuDialog: the whole screen on `bg-background-sidenav-bg backdrop-blur-md`, the close button
/// (`xl` tertiary IconButton, `top-6 right-6`, "ESC" below it), and `mx-auto flex h-screen max-w-270 px-4`: the
/// sidebar (`w-56 pr-6 pl-4`, `w-11` and icons only on phones: "Settings" in `title-2xl-semi-bold`, the groups, the
/// tab buttons `h-8 rounded-lg px-3`, the active one `bg-state-base-active system-sm-semibold`) and the content on
/// `bg-components-panel-bg` (reaching the screen's right edge): the tab's title (`mx-8 pt-8 pb-2
/// title-2xl-semi-bold`, staying at the top) over the page (`px-8 pt-6`), scrolling.
class AccountSetting extends StatefulWidget {
  const AccountSetting({
    super.key,
    required this.members,
    this.initialTab = AccountSettingTab.members,
    this.onTabChange,
    this.onCancel,
    this.items,
  });

  final WorkspaceMembers members;
  final AccountSettingTab initialTab;
  final ValueChanged<AccountSettingTab>? onTabChange;

  /// Defaults to closing the dialog.
  final VoidCallback? onCancel;

  /// The tabs ([accountSettingItems] by default).
  final List<AccountSettingItem>? items;

  @override
  State<AccountSetting> createState() => _AccountSettingState();
}

class _AccountSettingState extends State<AccountSetting> {
  late AccountSettingTab _tab = widget.initialTab;

  List<AccountSettingItem> get _items => widget.items ?? accountSettingItems;

  void _close() => widget.onCancel != null ? widget.onCancel!() : Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final title = stc(context, 'settings.settings');
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width <= 640; // use-breakpoints: mobile up to 640 px
    final items = _items;
    final active = items.firstWhere((i) => i.tab == _tab, orElse: () => items.first);
    final sidebarWidth = mobile ? 44.0 : 224.0;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        container: true,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: Focus(
            autofocus: true,
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: ColoredBox(
                  color: DifyColors.backgroundSidenavBg,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final boxWidth = c.maxWidth < 1080 ? c.maxWidth : 1080.0;
                      final contentLeft = (c.maxWidth - boxWidth) / 2 + 16 + sidebarWidth;
                      return Stack(
                        children: [
                          // The panel colour from the content's left edge to the screen's right edge.
                          Positioned(
                            left: contentLeft,
                            top: 0,
                            bottom: 0,
                            right: 0,
                            child: const ColoredBox(color: DifyColors.componentsPanelBg),
                          ),
                          Center(
                            child: SizedBox(
                              width: boxWidth,
                              height: c.maxHeight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(width: sidebarWidth, child: _sidebar(context, items, mobile)),
                                    Expanded(child: _content(context, active)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 24,
                            right: 24,
                            child: Column(
                              children: [
                                DifyIconButton(
                                  key: const ValueKey('account-setting-close'),
                                  label: stc(context, 'operation.close'),
                                  variant: DifyButtonVariant.tertiary,
                                  size: DifyIconButtonSize.xl,
                                  icon: const RemixIcon('close-line', size: 20),
                                  onPressed: _close,
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: ExcludeSemantics(
                                    child: Text(
                                      'ESC',
                                      style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidebar(BuildContext context, List<AccountSettingItem> items, bool mobile) {
    final groups = [
      for (final g in AccountSettingGroup.values)
        (
          group: g,
          items: [
            for (final i in items)
              if (i.group == g) i,
          ],
        ),
    ];
    return Padding(
      padding: mobile ? EdgeInsets.zero : const EdgeInsets.only(left: 16, right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 38,
            margin: const EdgeInsets.only(top: 24, bottom: 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              stc(context, 'settings.settings'),
              softWrap: false,
              overflow: TextOverflow.visible,
              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
            ),
          ),
          for (final g in groups)
            if (g.items.isNotEmpty)
              Padding(
                padding: g.group == AccountSettingGroup.workspace
                    ? const EdgeInsets.only(bottom: 8)
                    : const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (g.group == AccountSettingGroup.workspace && !mobile)
                      Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          difyTransform(DifyType.systemXsMediumUppercase, stc(context, 'settings.workspace')),
                          style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                        ),
                      ),
                    Container(
                      padding: g.group == AccountSettingGroup.user ? const EdgeInsets.only(top: 12) : null,
                      decoration: g.group == AccountSettingGroup.user
                          ? const BoxDecoration(
                              border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
                            )
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final i in g.items)
                            _TabButton(
                              key: ValueKey('account-setting-tab-${i.tab.name}'),
                              item: i,
                              active: i.tab == _tab,
                              mobile: mobile,
                              onTap: () {
                                setState(() => _tab = i.tab);
                                widget.onTabChange?.call(i.tab);
                              },
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

  Widget _content(BuildContext context, AccountSettingItem item) {
    final description = item.description?.call(context);
    return ColoredBox(
      color: DifyColors.componentsPanelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 60),
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.only(top: 32, bottom: 8),
            alignment: AlignmentDirectional.bottomStart,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (item.title ?? item.name)(context),
                  key: const ValueKey('account-setting-title'),
                  style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                ),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(description, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('account-setting-scroll'),
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width >= 640 ? 32 : 16,
                24,
                MediaQuery.sizeOf(context).width >= 640 ? 32 : 16,
                16,
              ),
              child: item.page(context, widget.members),
            ),
          ),
        ],
      ),
    );
  }
}

/// A sidebar tab: `mb-0.5 flex h-8 w-full items-center rounded-lg px-3 text-sm`, the icon (`size-4 mr-2`, filled
/// when active) and the name (hidden on phones); active `bg-state-base-active system-sm-semibold
/// text-components-menu-item-text-active`, else `system-sm-medium text-components-menu-item-text`. Named by the tab's
/// name.
class _TabButton extends StatelessWidget {
  const _TabButton({super.key, required this.item, required this.active, required this.mobile, required this.onTap});

  final AccountSettingItem item;
  final bool active, mobile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = item.name(context);
    final color = active ? DifyColors.componentsMenuItemTextActive : DifyColors.componentsMenuItemText;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: DifyPressable(
        semanticLabel: name,
        onPressed: onTap,
        builder: (context, hovered, focused) => Container(
          height: 32,
          padding: EdgeInsets.symmetric(horizontal: mobile ? 14 : 12),
          decoration: BoxDecoration(
            color: active ? DifyColors.stateBaseActive : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
          ),
          child: Row(
            children: [
              // Phones show the icon alone (in Dify it overflows the `w-11` column the same way).
              Padding(
                padding: EdgeInsets.only(right: mobile ? 0 : 8),
                child: RemixIcon(active ? item.activeIcon : item.icon, size: 16, color: color),
              ),
              if (!mobile)
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: difyTextStyle(active ? DifyType.systemSmSemibold : DifyType.systemSmMedium, color),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
